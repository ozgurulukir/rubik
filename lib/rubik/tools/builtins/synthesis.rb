# frozen_string_literal: true

require "json"
require "stringio"
require "timeout"
require_relative "../base"
require_relative "../output"
require_relative "../preflight_runner"
require_relative "../../runtime"

module Rubik
  module Tools
    class SynthesizeCommandTool < BaseTool
      DECLARATION = Declaration.new(
        name: "synthesize_command", aliases: ["create_command", "add_command"],
        description: "Dynamically create and register a new Rubik REPL bang command or tool at runtime (session, project, or global scope)",
        risk: :write, maestro_blocked: false, # self-evolution plane (TOOLS.md maestro policy)
        params_schema: {
          type: "object",
          properties: {
            name: { type: "string", description: "Name of the new command without '!' (e.g. 'db_seed', 'benchmark_api')" },
            description: { type: "string", description: "Short description of what the command does for !help" },
            scope: { type: "string", enum: ["session", "project", "global"],
                     description: "Storage scope: session (in-memory only), project (.rubik/commands), global (~/.rubik/commands)" },
            code: { type: "string", description: "Ruby handler code: ->(args, ctx) { ... }. For 2-arity, ctx is the OUTPUT VIEW " \
                                                 "(ctx.out / ctx.puts / ctx.print / ctx.flush). For config/services/full shell, " \
                                                 "declare 3-arity ->(args, out, shell) instead." },
            test_args: { type: "object", description: "Optional sample arguments to pre-flight verify the handler before registration (recommended)" }
          },
          required: ["name", "code"]
        }
      )
      def initialize(shell = nil, overlay_storage = nil, guard = nil, legacy_runtime_manager = nil, runtime_manager: nil)
        super(DECLARATION)
        @shell = shell
        # guard, fallback overlay storage'a da geçilir: bootstrap kabul taraması
        # aynı operatör-policy guard örneğini kullanır (bkz. OverlayStorage).
        @guard = guard || Rubik::Security::Guard.new
        @overlay_storage = overlay_storage || Rubik::Runtime::OverlayStorage.new(guard: @guard)
        @runtime_manager = runtime_manager || legacy_runtime_manager
      end

      def execute(args = {})
        # One canonical (downcased) spelling for guard checks, persistence, registration, and the dispose inverse.
        clean_name = (args["name"] || args[:name]).to_s.strip.delete_prefix("!").downcase
        name = clean_name
        description = (args["description"] || args[:description] || "Custom dynamic command").to_s.strip
        scope = (args["scope"] || args[:scope] || "session").to_s.downcase.to_sym
        code = (args["code"] || args[:code]).to_s.strip
        test_args = args["test_args"] || args[:test_args]

        return ToolOutput.error("Command name cannot be empty") if name.empty?
        return ToolOutput.error("Handler code cannot be empty") if code.empty?

        previous_meta = nil
        if @shell
          previous_meta = @shell.commands[clean_name]
          return ToolOutput.error("Cannot overwrite reserved built-in command '!#{clean_name}'") if previous_meta && !previous_meta[:custom]
        end

        # 1. Security & Syntax Verification
        begin
          Rubik::Security::Guard.run_synthesis_gate(@guard, code)
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

        unless proc_handler.respond_to?(:call)
          return ToolOutput.error("Code must evaluate to a callable Proc or Lambda " \
                                  "(e.g. ->(args, ctx) { ... } or ->(args, out, shell) { ... })")
        end

        # 1b. Optional pre-flight in an isolated child process (AGENTS.md §3.4):
        # verifies the handler actually runs before persistence/registration,
        # with a deadline even C extensions and blocking syscalls cannot preempt;
        # output goes to a throwaway StringIO so the terminal is never touched.
        if test_args
          preflight = PreflightRunner.run(code, test_args, mode: :command, guard: @guard)
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
          @shell.register_command(name, description: "#{description} [#{scope}]", custom: true) do |cmd_args, ctx|
            if proc_handler.arity == 1
              proc_handler.call(cmd_args)
            elsif proc_handler.arity == 2
              sealed_ctx = Rubik::Runtime::SynthesizedCommandContext.wrap(ctx, shell: @shell, runtime_manager: @runtime_manager)
              proc_handler.call(cmd_args, sealed_ctx)
            else
              # Trust model (issue #398): this raw else-branch serves EXPLICITLY authored 3-arity handlers only — bare bodies are rejected upstream by the callable check, so default saves never land here.
              # A 3-arity handler receives the RAW interactive shell (and its dispatch CommandContext via out_ctx) with `guard`, `config`, `buffer_manager`, etc. reachable — the SealedCoeffects deny-list does NOT apply.
              # That is the operator-trusted bootstrap contract, anchored to the synthesis-gate vocabulary above: the code passed run_synthesis_gate here AND, when persisted, its disk hash is verified against the manifest on load (verify_integrity; RUBIK_TRUST_OVERLAYS=1 is the blanket operator override). Authoring a 3-arity proc is the deliberate escape hatch; 2-arity handlers and bare-body overlay saves are sealed.
              out_ctx = if ctx
                          ctx
                        elsif @shell.respond_to?(:command_context)
                          warn "[rubik] custom command invoked without a dispatch CommandContext" unless ENV["RUBIK_TEST"]
                          @shell.command_context
                        else
                          @shell.output
                        end
              proc_handler.call(cmd_args, out_ctx.respond_to?(:out) ? out_ctx.out : out_ctx, @shell)
            end
          end

          # Sound rollback (AGENTS.md §1.A): a hot-updated custom command is
          # restored to its previous handler on dispose, not left as a hole.
          ctx = @runtime_manager&.context || (@shell.respond_to?(:runtime_manager) ? @shell.runtime_manager&.context : nil)
          if ctx.respond_to?(:on_dispose) || ctx.respond_to?(:register_disposable)
            hook = ctx.respond_to?(:on_dispose) ? :on_dispose : :register_disposable
            ctx.send(hook) do
              if previous_meta
                @shell.register_command(clean_name, description: previous_meta[:description],
                                                    custom: previous_meta[:custom], audience: previous_meta[:audience],
                                        &previous_meta[:handler])
              else
                @shell.unregister_command(name)
              end
            end
          else
            warn "[Synthesize] no runtime context; dispose inverse not registered for '!#{clean_name}'"
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
      DECLARATION = Declaration.new(
        name: "synthesize_tool", aliases: ["create_tool", "add_tool"],
        description: "Synthesize, verify, and register a new native function calling tool into the agent's live toolbelt " \
                     "at runtime (session, project, or global scope)",
        risk: :write, maestro_blocked: false, # self-evolution plane (TOOLS.md maestro policy)
        params_schema: {
          type: "object",
          properties: {
            name: { type: "string", description: "Name of the new tool (e.g. 'calc_stats', 'inspect_ast_node')" },
            description: { type: "string", description: "Clear explanation of what the tool does for model selection" },
            scope: { type: "string", enum: ["session", "project", "global"],
                     description: "Storage scope: session (in-memory only), project (.rubik/tools), global (~/.rubik/tools)" },
            risk: { type: "string", enum: ["read", "write", "execute"], default: "execute",
                    description: "Risk level of tool (optional; read/write/execute, default: execute)" },
            params_schema: {
              type: "object",
              description: "JSON Schema definition of the tool parameters (provide properties/required when the tool " \
                           "accepts arguments; defaults to an empty object schema `{ type: 'object', properties: {} }` " \
                           "for tools that take no arguments)"
            },
            code: { type: "string", description: "Ruby implementation of tool handler: ->(args) { ... } or ->(args, ctx) { ... }" },
            test_args: { type: "object", description: "Optional test arguments to perform pre-flight verification in an isolated sandbox" }
          },
          required: ["name", "description", "code"]
        }
      )
      def initialize(tool_registry = nil, overlay_storage = nil, guard = nil, legacy_runtime_manager = nil, runtime_manager: nil, runtime_context: nil)
        super(DECLARATION)
        @tool_registry = tool_registry
        # guard, fallback overlay storage'a da geçilir: bootstrap kabul taraması
        # aynı operatör-policy guard örneğini kullanır (bkz. OverlayStorage).
        @guard = guard || Rubik::Security::Guard.new
        @overlay_storage = overlay_storage || Rubik::Runtime::OverlayStorage.new(guard: @guard)
        @runtime_manager = runtime_manager || legacy_runtime_manager
        @runtime_context = runtime_context
      end

      def rebind_to(ctx)
        resolved_reg = ctx.respond_to?(:get) ? (ctx.get(Rubik::Coeffects::TOOL_REGISTRY) || ctx.get("tool_registry")) : (ctx["tool_registry"] if ctx.respond_to?(:[]))
        # The plane's registry wins even when it is this very instance: a fresh Registry would swap a live toolbelt for an empty one.
        new_registry = if resolved_reg then resolved_reg
                       elsif ctx.respond_to?(:provide)
                         scoped = Rubik::Tools::Registry.new(coeffect_ctx: ctx)
                         ctx.provide(Rubik::Coeffects::TOOL_REGISTRY, scoped)
                         scoped
                       else Rubik::Tools::Registry.new
                       end

        new_runtime_manager = if ctx.is_a?(Rubik::Runtime::Context) then Struct.new(:context).new(ctx)
                              elsif ctx.respond_to?(:context) then ctx
                              elsif ctx.respond_to?(:get) && ctx.get("runtime_manager") then ctx.get("runtime_manager")
                              else @runtime_manager
                              end

        new_runtime_ctx = if ctx.is_a?(Rubik::Runtime::Context) then ctx
                          elsif ctx.respond_to?(:context) && ctx.context.is_a?(Rubik::Runtime::Context) then ctx.context
                          else @runtime_context
                          end

        self.class.new(
          new_registry,
          @overlay_storage,
          @guard,
          runtime_manager: new_runtime_manager,
          runtime_context: new_runtime_ctx
        )
      end

      def execute(args = {})
        name = (args["name"] || args[:name]).to_s.strip.downcase.gsub(/[^a-z0-9_]/, "_")
        description = (args["description"] || args[:description] || "Custom native tool").to_s.strip
        scope = (args["scope"] || args[:scope] || "session").to_s.downcase.to_sym
        risk = (args["risk"] || args[:risk] || "execute").to_s.downcase.to_sym
        return ToolOutput.error("Invalid risk '#{risk}' — must be one of: read, write, execute.") unless [:read, :write, :execute].include?(risk)

        raw_schema = args["params_schema"] || args[:params_schema]
        schema_or_error = parse_params_schema(raw_schema)
        return schema_or_error if schema_or_error.is_a?(ToolOutput)

        schema = schema_or_error
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
          msg = "Cannot overwrite built-in tool '#{name}'. Choose a distinct name (e.g. 'my_#{name}')."
          return ToolOutput.error(msg)
        end

        # 1. Security & Pre-flight Syntax Verification in isolated Context
        begin
          Rubik::Security::Guard.run_synthesis_gate(@guard, code)
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
                            rt_ctx = active_context
                            Class.new(Rubik::Tools::BaseTool) do
                              define_method(:initialize) do
                                super(name: name, description: "#{description} [#{scope}]", risk: risk, params_schema: schema)
                                @handler = evaluated
                                @runtime_context = rt_ctx
                              end

                              define_method(:execute) do |exec_args = {}, ctx = nil|
                                if @handler.respond_to?(:arity) && @handler.arity.zero?
                                  @handler.call
                                elsif Rubik::Runtime::SynthesizedToolContext.accepts_context?(@handler)
                                  effective_ctx = ctx || @runtime_context || Rubik::Runtime::Context.new
                                  sealed_ctx = Rubik::Runtime::SynthesizedToolContext.wrap(effective_ctx)
                                  @handler.call(exec_args, sealed_ctx)
                                else
                                  @handler.call(exec_args)
                                end
                              end
                            end.new
                          else
                            return ToolOutput.error("Tool code must evaluate to a callable Proc (e.g. ->(args) { ... } or ->(args, ctx) { ... }).")
                          end

          if test_args
            ctx_for_preflight = active_context
            needs_in_process = Rubik::Runtime::SynthesizedToolContext.accepts_context?(evaluated) || evaluated.is_a?(Class)
            preflight = needs_in_process ? :in_process : PreflightRunner.run(code, test_args, mode: :tool, guard: @guard)
            return ToolOutput.error("Pre-flight verification failed for tool '#{name}': #{preflight}") if preflight.is_a?(String)

            if [:spawn_failed, :in_process].include?(preflight)
              sub_ctx = ctx_for_preflight.respond_to?(:extend) ? ctx_for_preflight.extend : nil
              begin
                failure = if evaluated.respond_to?(:call)
                            PreflightRunner.verify_in_process do
                              PreflightRunner.call_handler(evaluated, test_args, mode: :tool, context: sub_ctx || ctx_for_preflight)
                            end
                          else
                            PreflightRunner.verify_in_process { tool_instance.execute(test_args) }
                          end
                return ToolOutput.error("Pre-flight verification failed for tool '#{name}': #{failure}") if failure
              ensure
                sub_ctx&.dispose! if sub_ctx.respond_to?(:dispose!)
                sub_ctx&.dispose if sub_ctx.respond_to?(:dispose)
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
          ctx = active_context
          if ctx.respond_to?(:on_dispose) || ctx.respond_to?(:register_disposable)
            hook = ctx.respond_to?(:on_dispose) ? :on_dispose : :register_disposable
            ctx.send(hook) do
              if previous_tool && @tool_registry.respond_to?(:swap)
                @tool_registry.swap(name, previous_tool, origin: previous_origin || :overlay)
              else
                @tool_registry.unregister(name)
              end
            end
          end
        end

        verification_note = test_args ? "Pre-flight verified with provided test_args in an isolated sub-context." : "Pre-flight verification skipped (no test_args provided)."
        "🎉 Successfully synthesized and registered native tool '#{name}' [scope: #{scope}]. " \
          "#{verification_note} It is now immediately available in your active toolbelt for function calling."
      end

      private

      # Returns a params schema Hash, or a ToolOutput.error describing the problem.
      def parse_params_schema(raw_schema)
        return { type: "object", properties: {} } if raw_schema.nil? || (raw_schema.is_a?(String) && raw_schema.strip.empty?)
        return raw_schema if raw_schema.is_a?(Hash)

        parsed = JSON.parse(raw_schema.to_s)
        parsed.is_a?(Hash) ? parsed : ToolOutput.error("params_schema must be a valid JSON object schema (got #{parsed.class})")
      rescue JSON::ParserError => e
        ToolOutput.error("Invalid params_schema JSON: #{e.message}")
      end

      def active_context
        @runtime_context || (@runtime_manager&.context if @runtime_manager.respond_to?(:context)) ||
          (@tool_registry.coeffect_ctx if @tool_registry.respond_to?(:coeffect_ctx))
      end

      def clean_binding
        Object.new.instance_eval { binding }
      end
    end
  end
end
