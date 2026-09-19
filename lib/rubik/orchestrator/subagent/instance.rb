# frozen_string_literal: true

require "monitor"
require "json"
require "fileutils"

module Rubik
  module Orchestrator
    module Subagent
      # Autonomous background subagent execution instance running in an isolated
      # disposable sub-context with its own message inbox, tool slice, and lifecycle (Plan 94).
      class Instance
        attr_accessor :parent_id
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
          @started_at = nil
          @ended_at = nil
          @result = nil
          @last_error = nil
          @transcript_path = nil
          @transcript_uri = File.join(".rubik", "subagents", @id, "transcript.jsonl")
          @monitor = Monitor.new
          @thread = nil
          @context_cleaned_up = false
        end

        def running?
          @state == :running || @state == :waiting_input
        end

        def active?
          [:pending, :running, :waiting_input, :canceling].include?(@state)
        end

        def uptime
          return 0.0 unless @started_at

          ((@ended_at || Time.now) - @started_at).to_f
        end

        def post_message(message)
          @inbox.push(message)
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

            cleanup_context
            @state = :disposed
          end
        end

        def cleanup_context
          return if @context_cleaned_up

          @context_cleaned_up = true
          begin
            @context&.dispose unless @context&.disposed?
          rescue StandardError => e
            @last_error ||= "#{e.class}: #{e.message}"
          end
        end

        def to_h
          @monitor.synchronize do
            {
              id: @id, parent_id: @parent_id, role: @role, type: @type_name,
              state: @state.to_s, current_step: @current_step, max_steps: @max_steps,
              uptime_seconds: uptime.round(2), started_at: @started_at&.iso8601,
              ended_at: @ended_at&.iso8601, transcript: @transcript_path || @transcript_uri,
              last_error: @last_error, result_summary: @result&.to_s&.slice(0, 100),
              result: @result
            }
          end
        end

        def format_transcript
          lines = []
          @monitor.synchronize do
            lines = [
              "=== Subagent Transcript: [#{@id}] '#{@role}' (#{@type_name}) ===",
              "State: #{@state} | Steps: #{@current_step}/#{@max_steps} | Uptime: #{uptime.round(2)}s",
              "Started: #{@started_at&.iso8601} | Ended: #{@ended_at&.iso8601}",
              "Model: #{@model || 'default'} | Workspace: #{@workspace}",
              "---"
            ]

            @history.each do |entry|
              role = entry[:role] || entry["role"]
              content = entry[:content] || entry["content"]
              tcs = entry[:tool_calls] || entry["tool_calls"]
              t_name = entry[:tool_name] || entry["tool_name"]

              case role
              when "system"
                lines << "[SYSTEM PROMPT]\n#{content}\n---"
              when "user"
                lines << "[USER PROMPT]\n#{content}\n---"
              when "assistant"
                lines << "[ASSISTANT]\n#{content}" if content && !content.empty?
                if tcs && !tcs.empty?
                  tc_desc = tcs.map { |tc| "  • #{tc['tool'] || tc[:tool]}(#{tc['args'] || tc[:args]})" }.join("\n")
                  lines << "[TOOL CALLS]\n#{tc_desc}"
                end
                lines << "---"
              when "tool"
                text = content.to_s
                truncated = text.length > 2000 ? "#{text.slice(0, 2000)}\n... [truncated #{text.length - 2000} chars]" : text
                lines << "[TOOL RESULT: #{t_name}]\n#{truncated}\n---"
              end
            end

            lines << "[LAST ERROR]\n#{@last_error}\n---" if @last_error
            lines << "[FINAL RESULT]\n#{@result || '(no result recorded)'}"
          end
          lines.join("\n")
        end

        private

        def save_transcript!
          dir = File.join(@root_dir, ".rubik", "subagents", @id)
          FileUtils.mkdir_p(dir)
          file_path = File.join(dir, "transcript.jsonl")
          entries = @monitor.synchronize { @history.dup }
          File.open(file_path, "w") do |f|
            entries.each do |item|
              f.puts(Rubik::Platform.safe_json_generate(item))
            end
          end
          @transcript_path = file_path
          @transcript_uri = file_path
        rescue StandardError => e
          warn("[Subagent #{@id}] Failed to save transcript: #{e.class}: #{e.message}")
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
          while @current_step < @max_steps && @state == :running
            @current_step += 1
            drain_inbox_into_history

            tools_schemas = @tool_registry.respond_to?(:schemas) ? @tool_registry.schemas : []
            opts = { tools: tools_schemas }
            opts[:model] = @model unless @model.nil? || @model == "inherit"

            response = if @provider.respond_to?(:complete)
                         @provider.complete(@history, opts)
                       elsif @provider.respond_to?(:chat)
                         @provider.chat(@history, **opts)
                       else
                         raise "Provider #{@provider.class} does not support complete or chat"
                       end

            content = if response.respond_to?(:text)
                        response.text.to_s
                      elsif response.respond_to?(:content)
                        response.content.to_s
                      else
                        response.to_s
                      end

            raw_tcs = response.respond_to?(:tool_calls) ? response.tool_calls : []
            tool_calls = (raw_tcs || []).map.with_index do |tc, idx|
              cid = tc["id"] || tc[:id] || "call_#{@id}_#{@current_step}_#{idx + 1}"
              t_name = tc["tool"] || tc[:tool] || tc["name"] || tc[:name]
              t_args = tc["args"] || tc[:args] || tc["arguments"] || tc[:arguments] || {}
              t_args = JSON.parse(t_args) if t_args.is_a?(String)
              { "id" => cid, "tool" => t_name, "args" => t_args }
            end

            @history << {
              role: "assistant",
              content: content.empty? ? nil : content,
              tool_calls: tool_calls.empty? ? nil : tool_calls
            }

            if tool_calls.empty?
              @result = content.to_s.strip
              @state = :completed
              break
            elsif execute_tool_calls(tool_calls, fallback_content: content)
              @state = :completed
              break
            end
          end

          @monitor.synchronize do
            if @current_step >= @max_steps && @state == :running
              @state = :completed
              @result ||= "Subagent reached step budget (#{@max_steps} steps)."
            end
          end
        end

        def drain_inbox_into_history
          until @inbox.empty?
            msg = pop_inbox_safely
            @history << { role: "user", content: "[Message from supervisor]: #{msg}" } if msg
          end
        end

        def pop_inbox_safely
          @inbox.pop(true)
        rescue ThreadError
          nil
        end

        def execute_tool_calls(tool_calls, fallback_content: nil)
          finished = false
          tool_calls.each do |tc|
            name = tc["tool"]
            args = tc["args"] || {}
            call_id = tc["id"]

            if name == "finish"
              @result = args["message"] || args[:message] || fallback_content || "Completed"
              finished = true
              break
            end

            tool = @tool_registry.respond_to?(:get) ? @tool_registry.get(name) : nil
            output = if tool
                       begin
                         raw = tool.execute(args)
                         raw.respond_to?(:output) ? raw.output : raw.to_s
                       rescue StandardError => e
                         "Tool execution error: #{e.class}: #{e.message}"
                       end
                     else
                       "Tool '#{name}' is not available in subagent toolset."
                     end

            @history << {
              role: "tool",
              tool_call_id: call_id,
              tool_name: name,
              content: output.to_s
            }
          end
          finished
        end

        def build_effective_system_prompt
          directives = [
            "You are a specialized subagent operating under autonomous supervision.",
            "Subagent ID: #{@id} | Role: #{@role} | Type: #{@type_name}",
            "Perform your assigned task with high precision and provide a structured synthesis report."
          ]
          directives << "Custom Instructions:\n#{@system_prompt}" if @system_prompt && !@system_prompt.strip.empty?
          directives.join("\n\n")
        end
      end
    end
  end
end
