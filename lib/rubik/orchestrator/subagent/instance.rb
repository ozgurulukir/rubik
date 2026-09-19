# frozen_string_literal: true

require "monitor"
require "json"
require "fileutils"
require_relative "transcript_formatter"

module Rubik
  module Orchestrator
    module Subagent
      # Autonomous background subagent execution instance running in an isolated
      # disposable sub-context with its own message inbox, tool slice, and lifecycle (Plan 94).
      class Instance
        attr_accessor :parent_id, :on_budget_exhausted
        attr_reader :id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :context, :tool_registry, :buffer_manager,
                    :current_step, :max_steps, :state, :started_at, :ended_at, :result,
                    :last_error, :transcript_uri, :transcript_path, :history

        def initialize(id:, parent_id:, role:, type_name:, prompt:, context:, tool_registry:,
                       system_prompt: nil, workspace: "inherit", model: "inherit",
                       provider: nil, buffer_manager: nil, max_steps: 15, root_dir: Dir.pwd)
          @id = id.to_s
          @parent_id = parent_id.to_s
          @role = role.to_s.strip
          @type_name = type_name.to_s.downcase.strip
          @prompt = prompt.to_s.strip
          @system_prompt = system_prompt
          @workspace = workspace.to_s.downcase.strip
          @model = model
          @context = context
          @tool_registry = tool_registry
          @provider = provider
          @buffer_manager = buffer_manager
          @max_steps = (max_steps || 15).to_i
          @root_dir = root_dir

          @state = :pending
          @current_step = 0
          @history = []
          @inbox = Queue.new
          @started_at = @ended_at = @result = @last_error = @transcript_path = nil
          @transcript_uri = File.join(".rubik", "subagents", @id, "transcript.jsonl")
          @monitor = Monitor.new
          @budget_cond = @monitor.new_cond
          @warned_budget = @context_cleaned_up = false
          @on_budget_exhausted = @thread = nil
        end

        def running?
          @state == :running || @state == :waiting_input || @state == :waiting_budget
        end

        def active?
          [:pending, :running, :waiting_input, :waiting_budget, :canceling].include?(@state)
        end

        def uptime
          return 0.0 unless @started_at

          ((@ended_at || Time.now) - @started_at).to_f
        end

        def post_message(message, additional_steps: nil)
          @monitor.synchronize do
            @inbox.push(message)
            if @state == :waiting_budget || additional_steps
              extra = (additional_steps || 10).to_i
              extra = 10 if extra <= 0
              @max_steps += extra
              @warned_budget = false
              @state = :running
              @history << {
                role: "user",
                content: "[Supervisor init-0]: Budget extended by #{extra} steps with message. Total: #{@max_steps}."
              }
              @budget_cond.broadcast
            end
          end
        end

        def extend_budget(additional_steps = 10)
          @monitor.synchronize do
            return false if [:completed, :failed, :disposed].include?(@state)

            extra = (additional_steps || 10).to_i
            extra = 10 if extra <= 0
            @max_steps += extra
            @warned_budget = false
            was_waiting = @state == :waiting_budget || @state == :waiting_input
            @state = :running
            @history << {
              role: "user",
              content: "[Supervisor init-0]: Granted #{extra} additional step(s). Total budget: #{@max_steps}. Continue execution."
            }
            @budget_cond.broadcast if was_waiting
            true
          end
        end

        def start_async(&on_complete)
          @monitor.synchronize do
            return false if @thread&.alive?

            @started_at = Time.now
            @state = :running
          end

          @thread = Thread.new do
            run_execution_cycle
          ensure
            @ended_at ||= Time.now
            save_transcript! if @transcript_path.nil?
            cleanup_context
            on_complete&.call(self)
          end
          true
        end

        def kill
          @monitor.synchronize do
            return true if @state == :disposed

            @state = :canceling
            @ended_at = Time.now
            @budget_cond.broadcast
          end

          begin
            @thread&.kill if @thread&.alive?
          rescue StandardError
            nil
          end

          cleanup
          true
        end

        def cleanup
          @monitor.synchronize do
            return if @state == :disposed

            @budget_cond.broadcast
            cleanup_context
            @state = :disposed
          end
        end

        # Idempotent under monitor: check-and-set of @context_cleaned_up prevents
        # races between the worker's ensure block and kill's cleanup path.
        def cleanup_context
          @monitor.synchronize do
            return if @context_cleaned_up

            @context_cleaned_up = true
            begin
              @context&.dispose unless @context&.disposed?
            rescue StandardError => e
              @last_error ||= "#{e.class}: #{e.message}"
            end
          end
        end

        def to_h
          @monitor.synchronize do
            { id: @id, parent_id: @parent_id, role: @role, type: @type_name, state: @state.to_s,
              current_step: @current_step, max_steps: @max_steps, uptime_seconds: uptime.round(2),
              started_at: @started_at&.iso8601, ended_at: @ended_at&.iso8601,
              transcript: @transcript_path || @transcript_uri, last_error: @last_error,
              result_summary: @result&.to_s&.slice(0, 100), result: @result }
          end
        end

        def format_transcript
          TranscriptFormatter.format(self, @history, @monitor)
        end

        private

        def save_transcript!
          saved = TranscriptFormatter.save!(@root_dir, @id, @history, @monitor)
          return unless saved

          @transcript_path = @transcript_uri = saved
        end

        def run_execution_cycle
          effective_sys_prompt = build_effective_system_prompt
          @history << { role: "system", content: effective_sys_prompt }
          @history << { role: "user", content: @prompt }

          unless @provider
            @current_step += 1
            @result = "Subagent [#{@id}] (#{@role}) completed task successfully: #{@prompt.slice(0, 80)}"
            @state = :completed
            save_transcript!
            return
          end

          execute_steps_with_provider
          save_transcript!
        rescue StandardError => e
          @monitor.synchronize do
            @last_error = "#{e.class}: #{e.message}"
            @state = :failed
          end
          save_transcript!
        end

        def execute_steps_with_provider
          loop do
            while @current_step < @max_steps && @state == :running
              @current_step += 1
              drain_inbox_into_history
              inject_step_warning_if_needed

              opts = { tools: (@tool_registry.respond_to?(:schemas) ? @tool_registry.schemas : []) }
              opts[:model] = @model unless @model.nil? || @model == "inherit"

              content, tool_calls = parse_provider_response(invoke_provider(opts))
              @history << {
                role: "assistant",
                content: (content.empty? ? nil : content),
                tool_calls: (tool_calls.empty? ? nil : tool_calls)
              }

              next unless tool_calls.empty? || execute_tool_calls(tool_calls, fallback_content: content)

              @result = content.to_s.strip if tool_calls.empty?
              @state = :completed
              return
            end

            break unless @state == :running && @current_step >= @max_steps

            break unless pause_and_await_budget_expansion!
          end
        end

        def inject_step_warning_if_needed
          warn_step = (@max_steps * 0.75).ceil
          return if @warned_budget || @current_step < warn_step || @current_step >= @max_steps

          remaining = @max_steps - @current_step
          @warned_budget = true
          @history << {
            role: "user",
            content: "[Step budget warning]: Used #{@current_step}/#{@max_steps} steps (#{remaining} remaining). " \
                     "Conclude work or prepare progress summary for init-0 supervisor."
          }
        end

        def pause_and_await_budget_expansion!(wait_timeout = 60)
          @monitor.synchronize do
            return false unless @state == :running

            @state = :waiting_budget
            @result = "Subagent reached step budget (#{@max_steps} steps). Awaiting budget expansion from init-0."
          end

          @on_budget_exhausted&.call(self)

          @monitor.synchronize do
            @budget_cond.wait(wait_timeout) if @state == :waiting_budget
            if @state == :waiting_budget
              @state = :completed
              @result = "Subagent reached step budget (#{@max_steps} steps) and concluded after waiting for init-0."
              false
            else
              @state == :running
            end
          end
        end

        def invoke_provider(opts)
          return @provider.complete(@history, opts) if @provider.respond_to?(:complete)
          return @provider.chat(@history, **opts) if @provider.respond_to?(:chat)

          raise "Provider #{@provider.class} does not support complete or chat"
        end

        def parse_provider_response(response)
          content = extract_response_content(response)
          raw_tcs = response.respond_to?(:tool_calls) ? response.tool_calls : []
          tool_calls = (raw_tcs || []).map.with_index do |tc, idx|
            cid = tc["id"] || tc[:id] || "call_#{@id}_#{@current_step}_#{idx + 1}"
            t_name = tc["tool"] || tc[:tool] || tc["name"] || tc[:name]
            t_args = tc["args"] || tc[:args] || tc["arguments"] || tc[:arguments] || {}
            t_args = JSON.parse(t_args) if t_args.is_a?(String)
            { "id" => cid, "tool" => t_name, "args" => t_args }
          end
          [content, tool_calls]
        end

        def extract_response_content(response)
          return response.text.to_s if response.respond_to?(:text)
          return response.content.to_s if response.respond_to?(:content)

          response.to_s
        end

        def drain_inbox_into_history
          until @inbox.empty?
            begin
              msg = @inbox.pop(true)
              @history << { role: "user", content: "[Message from supervisor]: #{msg}" } if msg
            rescue ThreadError
              break
            end
          end
        end

        def execute_tool_calls(tool_calls, fallback_content: nil)
          finished = false
          tool_calls.each do |tc|
            name = tc["tool"]
            args = tc["args"] || {}
            if name == "finish"
              @result = args["message"] || args[:message] || fallback_content || "Completed"
              finished = true
              break
            end

            tool = @tool_registry.respond_to?(:get) ? @tool_registry.get(name) : nil
            output = dispatch_subagent_tool(tool, name, args)
            @history << { role: "tool", tool_call_id: tc["id"], tool_name: name, content: output.to_s }
          end
          finished
        end

        def dispatch_subagent_tool(tool, name, args)
          return "Tool '#{name}' is not available in subagent toolset." unless tool

          raw = tool.execute(args)
          raw.respond_to?(:output) ? raw.output : raw.to_s
        rescue StandardError => e
          "Tool execution error: #{e.class}: #{e.message}"
        end

        def build_effective_system_prompt
          base = "You are a specialized subagent operating under autonomous supervision.\n\n" \
                 "Subagent ID: #{@id} | Role: #{@role} | Type: #{@type_name}\n\n" \
                 "Perform your assigned task with high precision and provide a structured synthesis report."
          @system_prompt && !@system_prompt.strip.empty? ? "#{base}\n\nCustom Instructions:\n#{@system_prompt}" : base
        end
      end
    end
  end
end
