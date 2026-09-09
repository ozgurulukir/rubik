# frozen_string_literal: true

require "timeout"
require_relative "../base"
require_relative "../output"
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
              code: { type: "string", description: "Ruby handler code: ->(args, out, shell) { ... }" }
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

        return ToolOutput.error("Command name cannot be empty") if name.empty?
        return ToolOutput.error("Handler code cannot be empty") if code.empty?

        clean_name = name.to_s.downcase.delete_prefix("!")
        if @shell
          existing_cmd = @shell.instance_variable_get(:@commands)&.dig(clean_name)
          return ToolOutput.error("Cannot overwrite reserved built-in command '!#{clean_name}'") if existing_cmd && !existing_cmd[:custom]
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

          # Register inverse in Runtime Context
          if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
            @runtime_manager.context.on_dispose do
              @shell.unregister_command(name)
            end
          end
        end

        "Successfully synthesized and registered !#{name} [scope: #{scope}]. You can now run it using !#{name} or via exec_repl_command('!#{name}')."
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
            sub_ctx = @runtime_manager&.context.is_a?(Rubik::Runtime::Context) ? @runtime_manager.context.extend : nil
            # Architectural safety note: Timeout.timeout uses Ruby's Thread.raise/kill semantics.
            # While effective for guarding against runaway pure-Ruby loops during synthesis pre-flight
            # verification, blocking C extensions or uninterruptible syscalls cannot be preempted.
            begin
              Timeout.timeout(5) do
                tool_instance.execute(test_args)
              end
            rescue Timeout::Error
              return ToolOutput.error("Pre-flight verification failed for tool '#{name}': execution timed out after 5 seconds")
            ensure
              sub_ctx&.dispose!
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

        "🎉 Successfully synthesized and registered native tool '#{name}' [scope: #{scope}]. " \
          "It is now immediately available in your active toolbelt for function calling."
      end

      private

      def clean_binding
        Object.new.instance_eval { binding }
      end
    end
  end
end
