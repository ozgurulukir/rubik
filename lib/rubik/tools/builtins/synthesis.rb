# frozen_string_literal: true

require "stringio"
require "timeout"
require_relative "../base"
require_relative "../output"
require_relative "../preflight_runner"
require_relative "../../runtime"

module Rubik
  module Tools
    class SynthesizeCommandTool < BaseTool
      def initialize(shell = nil, overlay_storage = nil, guard = nil, legacy_runtime_manager = nil, runtime_manager: nil)
        super(
          name: "synthesize_command",
          aliases: ["create_command", "add_command"],
          description: "Dynamically create and register a new Rubik REPL bang command or tool at runtime (session, project, or global scope)",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Name of the new command without '!' (e.g. 'db_seed', 'benchmark_api')" },
              description: { type: "string", description: "Short description of what the command does for !help" },
              scope: { type: "string", enum: ["session", "project", "global"],
                       description: "Storage scope: session (in-memory only), project (.rubik/commands), global (~/.rubik/commands)" },
              code: { type: "string", description: "Ruby handler code: ->(args, out, shell) { ... }" },
              test_args: { type: "object", description: "Optional sample arguments to pre-flight verify the handler before registration (recommended)" }
            },
            required: ["name", "code"]
          }
        )
        @shell = shell
        @overlay_storage = overlay_storage || Rubik::Runtime::OverlayStorage.new
        @guard = guard || Rubik::Security::Guard.new
        @runtime_manager = runtime_manager || legacy_runtime_manager
      end

      def execute(args = {})
        name = (args["name"] || args[:name]).to_s.strip.delete_prefix("!")
        description = (args["description"] || args[:description] || "Custom dynamic command").to_s.strip
        scope = (args["scope"] || args[:scope] || "session").to_s.downcase.to_sym
        code = (args["code"] || args[:code]).to_s.strip
        test_args = args["test_args"] || args[:test_args]

        return ToolOutput.error("Command name cannot be empty") if name.empty?
        return ToolOutput.error("Handler code cannot be empty") if code.empty?

        clean_name = name.to_s.downcase.delete_prefix("!")
        previous_meta = nil
        if @shell
          previous_meta = @shell.commands[clean_name]
          return ToolOutput.error("Cannot overwrite reserved built-in command '!#{clean_name}'") if previous_meta && !previous_meta[:custom]
        end

        # 1. Security & Syntax Verification
        begin
          if @guard.respond_to?(:verify_synthesis_safety!)
            @guard.verify_synthesis_safety!(code)
          else
            @guard.verify_command_safety!(code)
          end
        rescue Rubik::Security::BlockedWriteError => e
          return ToolOutput.error("Security blocked: #{e.message}")
        rescue StandardError => e
          return ToolOutput.error("Security blocked: Synthesized command code contains dangerous operations (#{e.message})")
        end

        proc_handler = begin
          eval(code, clean_binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- sentez çekirdegi; @guard.verify_synthesis_safety! ön kosulu çalisir
        rescue ScriptError, StandardError => e
          return ToolOutput.error("Syntax error in synthesized code: #{e.message}") # rubocop:disable Lint/NoReturnInBeginEndBlocks -- araç hata akisinda bilinçli erken dönüş
        end

        return ToolOutput.error("Code must evaluate to a callable Proc or Lambda (e.g. ->(args, out, shell) { ... })") unless proc_handler.respond_to?(:call)

        # 1b. Optional pre-flight execution in an isolated child process
        # (AGENTS.md §3.4): verifies the handler actually runs before it is
        # persisted or registered. A subprocess guarantees the deadline even
        # for C extensions and blocking syscalls that Timeout.timeout cannot
        # preempt; output goes to a throwaway StringIO inside the child so
        # verification never writes to the user's terminal.
        if test_args
          preflight = PreflightRunner.run(code, test_args, mode: :command)
          return ToolOutput.error("Pre-flight verification failed for command '!#{name}': #{preflight}") if preflight.is_a?(String)

          if preflight == :spawn_failed
            sub_ctx = @runtime_manager&.context.is_a?(Rubik::Runtime::Context) ? @runtime_manager.context.extend : nil
            begin
              failure = PreflightRunner.verify_in_process { PreflightRunner.call_handler(proc_handler, test_args, mode: :command, shell: @shell) }
              return ToolOutput.error("Pre-flight verification failed for command '!#{name}': #{failure}") if failure
            ensure
              sub_ctx&.dispose
            end
          end
        end

        # 2. Persist to storage if scope is project or global
        if [:project, :global].include?(scope)
          save_res = @overlay_storage.save_command(name, code, scope: scope, description: description)
          return ToolOutput.error("Failed to persist command: #{save_res[:error]}") unless save_res[:ok]
        end

        # 3. Register live in REPL shell
        if @shell
          @shell.register_command(name, description: "#{description} [#{scope}]", custom: true) do |cmd_args|
            out = @shell.output
            if proc_handler.arity == 1
              proc_handler.call(cmd_args)
            elsif proc_handler.arity == 2
              proc_handler.call(cmd_args, out)
            else
              proc_handler.call(cmd_args, out, @shell)
            end
          end

          # Register inverse in Runtime Context. Sound rollback (AGENTS.md §1.A):
          # a hot-updated custom command is restored to its previous handler on
          # dispose instead of leaving a hole in the command table.
          if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
            @runtime_manager.context.on_dispose do
              if previous_meta
                @shell.register_command(clean_name, description: previous_meta[:description],
                                                    custom: previous_meta[:custom], audience: previous_meta[:audience],
                                        &previous_meta[:handler])
              else
                @shell.unregister_command(name)
              end
            end
          end
        end

        "Successfully synthesized and registered !#{name} [scope: #{scope}]#{' (pre-flight verified)' if test_args}. " \
          "You can now run it using !#{name} or via exec_repl_command('!#{name}')."
      end

      private

      def clean_binding
        Object.new.instance_eval { binding }
      end
    end

    class SynthesizeToolTool < BaseTool
      def initialize(tool_registry = nil, overlay_storage = nil, guard = nil, legacy_runtime_manager = nil, runtime_manager: nil)
        super(
          name: "synthesize_tool",
          aliases: ["create_tool", "add_tool"],
          description: "Synthesize, verify, and register a new native function calling tool into the agent's live toolbelt " \
                       "at runtime (session, project, or global scope)",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Name of the new tool (e.g. 'calc_stats', 'inspect_ast_node')" },
              description: { type: "string", description: "Clear explanation of what the tool does for model selection" },
              scope: { type: "string", enum: ["session", "project", "global"],
                       description: "Storage scope: session (in-memory only), project (.rubik/tools), global (~/.rubik/tools)" },
              risk: { type: "string", enum: ["read", "write", "execute"], default: "execute",
                      description: "Risk level of tool (optional; read/write/execute, default: execute)" },
              params_schema: { type: "object", description: "JSON Schema definition of the tool parameters" },
              code: { type: "string", description: "Ruby implementation of tool handler: ->(args) { ... } or class extending Rubik::Tools::BaseTool" },
              test_args: { type: "object", description: "Optional test arguments to perform pre-flight verification in an isolated sandbox" }
            },
            required: ["name", "description", "code"]
          }
        )
        @tool_registry = tool_registry
        @overlay_storage = overlay_storage || Rubik::Runtime::OverlayStorage.new
        @guard = guard || Rubik::Security::Guard.new
        @runtime_manager = runtime_manager || legacy_runtime_manager
      end

      def execute(args = {})
        name = (args["name"] || args[:name]).to_s.strip.downcase.gsub(/[^a-z0-9_]/, "_")
        description = (args["description"] || args[:description] || "Custom native tool").to_s.strip
        scope = (args["scope"] || args[:scope] || "session").to_s.downcase.to_sym
        risk = (args["risk"] || args[:risk] || "execute").to_s.downcase.to_sym
        schema = args["params_schema"] || args[:params_schema] || { type: "object", properties: {} }
        code = (args["code"] || args[:code]).to_s.strip
        test_args = args["test_args"] || args[:test_args]

        return ToolOutput.error("Tool name cannot be empty") if name.empty?
        return ToolOutput.error("Tool code cannot be empty") if code.empty?

        # Guard against shadowing built-in tools. Registry#register silently
        # overwrites, and the dispose inverse only unregisters — a synthesized
        # "read_file" would leave the session without the real read_file after
        # disposal. Built-ins are rejected here; overlay/MCP/synthesized tools
        # may be hot-updated (previous instance is restored on dispose).
        previous_tool = @tool_registry&.get(name)
        if previous_tool && @tool_registry.origin(name) == :builtin
          return ToolOutput.error("Cannot overwrite built-in tool '#{name}'. Choose a distinct name (e.g. 'my_#{name}').")
        end

        # 1. Security & Pre-flight Syntax Verification in isolated Context
        begin
          if @guard.respond_to?(:verify_synthesis_safety!)
            @guard.verify_synthesis_safety!(code)
          else
            @guard.verify_command_safety!(code)
          end
        rescue Rubik::Security::BlockedWriteError => e
          return ToolOutput.error("Security blocked: #{e.message}")
        rescue StandardError => e
          return ToolOutput.error("Security blocked: Synthesized tool code contains dangerous operations (#{e.message})")
        end

        tool_instance = nil
        begin
          evaluated = eval(code, clean_binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- sentez çekirdegi
          tool_instance = if evaluated.is_a?(Class) && evaluated < Rubik::Tools::BaseTool
                            evaluated.new
                          elsif evaluated.respond_to?(:call)
                            Class.new(Rubik::Tools::BaseTool) do
                              define_method(:initialize) do
                                super(name: name, description: "#{description} [#{scope}]", risk: risk, params_schema: schema)
                                @handler = evaluated
                              end

                              define_method(:execute) do |exec_args = {}|
                                @handler.call(exec_args)
                              end
                            end.new
                          else
                            return ToolOutput.error("Tool code must evaluate to a callable Proc (->(args) { ... }) or a BaseTool subclass.")
                          end

          if test_args
            preflight = PreflightRunner.run(code, test_args, mode: :tool)
            return ToolOutput.error("Pre-flight verification failed for tool '#{name}': #{preflight}") if preflight.is_a?(String)

            if preflight == :spawn_failed
              # Fallback: in-process Timeout (lambda form via the shared
              # dispatch; BaseTool-subclass form needs the full runtime and
              # always verifies in-process).
              sub_ctx = @runtime_manager&.context.is_a?(Rubik::Runtime::Context) ? @runtime_manager.context.extend : nil
              begin
                failure = if evaluated.respond_to?(:call)
                            PreflightRunner.verify_in_process { PreflightRunner.call_handler(evaluated, test_args, mode: :tool) }
                          else
                            PreflightRunner.verify_in_process { tool_instance.execute(test_args) }
                          end
                return ToolOutput.error("Pre-flight verification failed for tool '#{name}': #{failure}") if failure
              ensure
                sub_ctx&.dispose!
              end
            end
          end
        rescue ScriptError, StandardError => e
          return ToolOutput.error("Pre-flight verification failed for tool '#{name}': #{e.message}")
        end

        # 2. Persist to storage if scope is project or global
        if [:project, :global].include?(scope)
          save_res = @overlay_storage.save_tool(name, code, scope: scope, description: description, params_schema: schema, risk: risk)
          return ToolOutput.error("Failed to persist tool: #{save_res[:error]}") unless save_res[:ok]
        end

        # 3. Register live into active tool registry
        if @tool_registry
          previous_origin = previous_tool ? @tool_registry.origin(name) : nil
          @tool_registry.register(tool_instance, origin: :synthesis)

          # Register inverse in Runtime Context. When hot-updating an existing
          # overlay/MCP/synthesized tool, the inverse restores the previous
          # instance instead of leaving a hole in the toolbelt.
          if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
            @runtime_manager.context.on_dispose do
              if previous_tool
                @tool_registry.swap(name, previous_tool, origin: previous_origin || :overlay)
              else
                @tool_registry.unregister(name)
              end
            end
          end
        end

        verification_note = if test_args
                              "Pre-flight verified in an isolated sub-context."
                            else
                              "Syntax-verified only; pass test_args for runtime pre-flight verification."
                            end
        "🎉 Successfully synthesized and registered native tool '#{name}' [scope: #{scope}]. " \
          "#{verification_note} It is now immediately available in your active toolbelt for function calling."
      end

      private

      def clean_binding
        Object.new.instance_eval { binding }
      end
    end
  end
end
