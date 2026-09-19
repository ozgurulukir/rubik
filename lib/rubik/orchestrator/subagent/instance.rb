# frozen_string_literal: true

require "monitor"

module Rubik
  module Orchestrator
    module Subagent
      # Autonomous background subagent execution instance running in an isolated
      # disposable sub-context with its own message inbox, tool slice, and lifecycle (Plan 94).
      class Instance
        attr_reader :id, :parent_id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :context, :tool_registry, :current_step,
                    :max_steps, :state, :started_at, :ended_at, :result,
                    :last_error, :transcript_uri, :history

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
          @transcript_uri = "rubik://subagent/#{@id}/transcript"
          @monitor = Monitor.new
          @thread = nil
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
            on_complete&.call(self)
          end
          true
        end

        def kill
          @monitor.synchronize do
            return true if @state == :disposed || @state == :completed

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

            begin
              @context&.dispose unless @context&.disposed?
            rescue StandardError
              nil
            end
            @state = :disposed
          end
        end

        def to_h
          @monitor.synchronize do
            {
              id: @id,
              parent_id: @parent_id,
              role: @role,
              type: @type_name,
              state: @state.to_s,
              current_step: @current_step,
              max_steps: @max_steps,
              uptime_seconds: uptime.round(2),
              started_at: @started_at&.iso8601,
              ended_at: @ended_at&.iso8601,
              transcript: @transcript_uri,
              last_error: @last_error,
              result_summary: @result&.to_s&.slice(0, 100)
            }
          end
        end

        private

        def run_execution_cycle
          effective_sys_prompt = build_effective_system_prompt
          @history << { role: "system", content: effective_sys_prompt }
          @history << { role: "user", content: @prompt }

          # If no LLM provider injected (e.g. unit testing or standalone mode), simulate deterministic completion
          unless @provider
            @current_step += 1
            @result = "Subagent [#{@id}] (#{@role}) completed task successfully: #{@prompt.slice(0, 80)}"
            @state = :completed
            return
          end

          execute_steps_with_provider
        rescue StandardError => e
          @monitor.synchronize do
            @last_error = "#{e.class}: #{e.message}"
            @state = :failed
          end
        end

        def execute_steps_with_provider
          while @current_step < @max_steps && @state == :running
            @current_step += 1

            # Check inbox for mid-run messages
            drain_inbox_into_history

            tools_schemas = @tool_registry.respond_to?(:schemas) ? @tool_registry.schemas : []
            opts = { tools: tools_schemas }
            opts[:model] = @model unless @model.nil? || @model == "inherit"

            response = @provider.chat(@history, **opts)
            content = response.respond_to?(:content) ? response.content : response.to_s
            tool_calls = response.respond_to?(:tool_calls) ? response.tool_calls : []

            @history << { role: "assistant", content: content, tool_calls: tool_calls }

            if tool_calls.nil? || tool_calls.empty?
              @result = content.to_s.strip
              @state = :completed
              break
            end

            # Execute tool calls
            finish_encountered = execute_tool_calls(tool_calls)
            if finish_encountered
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

        def execute_tool_calls(tool_calls)
          finished = false
          tool_calls.each do |call|
            name = call[:name] || call["name"]
            args = call[:arguments] || call["arguments"] || {}
            args = JSON.parse(args) if args.is_a?(String)

            if name == "finish"
              @result = args["message"] || args[:message] || "Completed"
              finished = true
              break
            end

            tool = @tool_registry.respond_to?(:get) ? @tool_registry.get(name) : nil
            output = if tool
                       begin
                         tool.execute(args)
                       rescue StandardError => e
                         "Tool execution error: #{e.class}: #{e.message}"
                       end
                     else
                       "Tool '#{name}' is not available in subagent toolset."
                     end

            @history << { role: "tool", tool_name: name, content: output.to_s }
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
