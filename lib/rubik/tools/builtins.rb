# frozen_string_literal: true

require_relative "base"
require_relative "../runtime"

module Rubik
  module Tools
    class ReadFileTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "read_file",
          description: "Read content of a file from buffer or disk",
          risk: :read,
          params_schema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] }
        )
        @buffer_manager = buffer_manager
      end

      def execute(args = {})
        path = args["path"] || args[:path]
        content = @buffer_manager.read(path)
        content || "File not found: #{path}"
      end
    end

    class WriteFileTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "write_file",
          description: "Write content to the in-memory buffer (does not write to disk until !apply)",
          risk: :write,
          params_schema: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: %w[path content] }
        )
        @buffer_manager = buffer_manager
      end

      def execute(args = {})
        path = args["path"] || args[:path]
        content = args["content"] || args[:content]
        @buffer_manager.write(path, content)
        "Successfully wrote to in-memory buffer: #{path}"
      end
    end

    class ListFilesTool < BaseTool
      def initialize(context_index, root_dir: Dir.pwd)
        super(
          name: "list_files",
          description: "List project files matching an optional path prefix or extension filter",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              path: { type: "string", description: "Subdirectory or path prefix to filter (optional)" },
              extension: { type: "string", description: "File extension filter, e.g. .rb, .go, .zig (optional)" }
            }
          }
        )
        @context_index = context_index
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        path_filter = args["path"] || args[:path]
        ext_filter = args["extension"] || args[:extension]

        files = @context_index.files.empty? ? @context_index.full_scan : @context_index.files
        file_list = files.keys

        file_list = file_list.select { |f| f.start_with?(path_filter.sub(%r{^\./}, "")) } if path_filter && !path_filter.empty?
        file_list = file_list.select { |f| f.end_with?(ext_filter) } if ext_filter && !ext_filter.empty?

        if file_list.empty?
          "No matching files found."
        else
          "Found #{file_list.size} file(s):\n#{file_list.first(50).map { |f| " - #{f}" }.join("\n")}"
        end
      end
    end

    class SearchSymbolsTool < BaseTool
      def initialize(ast_graph)
        super(
          name: "search_symbols",
          description: "Search function, class, struct definitions and call hierarchies in the AST symbol graph",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              query: { type: "string", description: "Symbol name or partial name to search" },
              smart_context: { type: "boolean", description: "Return full smart context with dependencies (optional)" }
            },
            required: ["query"]
          }
        )
        @ast_graph = ast_graph
      end

      def execute(args = {})
        query = (args["query"] || args[:query]).to_s.strip
        return "Query parameter required" if query.empty?

        if args["smart_context"] || args[:smart_context]
          ctx = @ast_graph.smart_context_for(query)
          return ctx.empty? ? "No smart context found for '#{query}'." : ctx
        end

        matches = @ast_graph.symbols.values.select do |sym|
          sym.name.downcase.include?(query.downcase)
        end

        if matches.empty?
          "No symbols found matching '#{query}'."
        else
          matches.map do |sym|
            "• #{sym.kind.to_s.upcase} #{sym.name} (#{sym.file}:#{sym.line_start}-#{sym.line_end})\n  Signature: #{sym.signature}\n  Calls: #{sym.calls.join(', ')}"
          end.join("\n\n")
        end
      end
    end

    class GetOutlineTool < BaseTool
      def initialize(ast_graph)
        super(
          name: "get_outline",
          description: "Get high-level semantic outline (classes, methods, functions, and line ranges) of a source file from the AST without reading entire file content",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to source file to inspect" }
            },
            required: ["file_path"]
          }
        )
        @ast_graph = ast_graph
      end

      def execute(args = {})
        path = (args["file_path"] || args[:file_path] || args["path"] || args[:path]).to_s.strip
        return "File path is required" if path.empty?
        return "AST graph is not available" unless @ast_graph

        @ast_graph.outline_for(path)
      end
    end

    class FindReferencesTool < BaseTool
      def initialize(ast_graph)
        super(
          name: "find_references",
          description: "Find all call sites, callers, and references of a symbol/function/class across the workspace for safe refactoring",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              symbol_name: { type: "string", description: "Symbol name to find callers/references for" }
            },
            required: ["symbol_name"]
          }
        )
        @ast_graph = ast_graph
      end

      def execute(args = {})
        sym_name = (args["symbol_name"] || args[:symbol_name] || args["symbol"] || args[:symbol]).to_s.strip
        return "Symbol name is required" if sym_name.empty?
        return "AST graph is not available" unless @ast_graph

        callers = @ast_graph.callers_of(sym_name)
        if callers.empty?
          "No references or callers found for '#{sym_name}' in AST graph."
        else
          lines = ["Found #{callers.size} reference(s) for '#{sym_name}':"]
          callers.each do |c|
            lines << "  • #{c.name} (#{c.file}:#{c.line_start}-#{c.line_end}) -> #{c.signature}"
          end
          lines.join("\n")
        end
      end
    end

    class GetSymbolTool < BaseTool
      def initialize(ast_graph)
        super(
          name: "get_symbol",
          description: "Get isolated definition, signature, docstring, and body of a specific class or method from the AST",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              symbol_name: { type: "string", description: "Symbol name to retrieve definition for" }
            },
            required: ["symbol_name"]
          }
        )
        @ast_graph = ast_graph
      end

      def execute(args = {})
        sym_name = (args["symbol_name"] || args[:symbol_name] || args["symbol"] || args[:symbol]).to_s.strip
        return "Symbol name is required" if sym_name.empty?
        return "AST graph is not available" unless @ast_graph

        info = @ast_graph.symbol_definition(sym_name)
        return "Symbol '#{sym_name}' not found in AST graph." unless info

        lines = [
          "Symbol: #{info[:name]} [#{info[:kind].to_s.upcase}]",
          "File: #{info[:file]} (lines #{info[:line_start]}-#{info[:line_end]})",
          "Signature: #{info[:signature]}"
        ]
        lines << "Docstring: #{info[:docstring]}" if info[:docstring] && !info[:docstring].empty?
        lines << "Calls: #{info[:calls].join(', ')}" unless info[:calls].empty?
        lines << "\n--- Body ---\n#{info[:body]}" if info[:body] && !info[:body].empty?
        lines.join("\n")
      end
    end

    class LSPDiagnosticsTool < BaseTool
      def initialize(lsp_manager = nil)
        super(
          name: "lsp_diagnostics",
          description: "Get real-time compiler and linter diagnostics (errors, warnings) for a file or all active project files via LSP",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Optional specific file path to query diagnostics for" }
            }
          }
        )
        @lsp_manager = lsp_manager
      end

      def execute(args = {})
        return "LSP manager is not connected" unless @lsp_manager
        return "LSP is currently disabled in configuration (enable via '!lsp on')" unless @lsp_manager.enabled?

        path = (args["file_path"] || args[:file_path] || "").to_s.strip

        if !path.empty?
          diags = @lsp_manager.diagnostics_for(path)
          if diags.empty?
            "No LSP diagnostics or errors for '#{path}'."
          else
            lines = ["=== LSP Diagnostics for #{path} (#{diags.size} issue(s)) ==="]
            diags.each do |d|
              sev = case d["severity"]
                    when 1 then "ERROR"
                    when 2 then "WARN"
                    when 3 then "INFO"
                    else "HINT"
                    end
              range = d["range"] || {}
              start_line = (range.dig("start", "line") || 0) + 1
              start_char = (range.dig("start", "character") || 0) + 1
              lines << "  • [#{sev}] Line #{start_line}:#{start_char} - #{d['message']}"
            end
            lines.join("\n")
          end
        else
          all = @lsp_manager.all_diagnostics
          total_issues = all.values.flatten.size
          if total_issues.zero?
            "No active LSP diagnostics across workspace (all clean)."
          else
            lines = ["=== Active Workspace LSP Diagnostics (#{total_issues} issue(s)) ==="]
            all.each do |fpath, diags|
              next if diags.empty?

              lines << "\nFile: #{fpath} (#{diags.size}):"
              diags.each do |d|
                sev = d["severity"] == 1 ? "ERROR" : "WARN"
                start_line = (d.dig("range", "start", "line") || 0) + 1
                lines << "  • [#{sev}] Line #{start_line}: #{d['message']}"
              end
            end
            lines.join("\n")
          end
        end
      end
    end

    class LSPHoverTool < BaseTool
      def initialize(lsp_manager = nil)
        super(
          name: "lsp_hover",
          description: "Get compiler-level type signature, docstring, and symbol details at a specific line and character position via LSP",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to source file" },
              line: { type: "integer", description: "1-based line number" },
              character: { type: "integer", description: "1-based character position" }
            },
            required: %w[file_path line character]
          }
        )
        @lsp_manager = lsp_manager
      end

      def execute(args = {})
        return "LSP manager is not connected" unless @lsp_manager
        return "LSP is currently disabled in configuration (enable via '!lsp on')" unless @lsp_manager.enabled?

        path = (args["file_path"] || args[:file_path]).to_s.strip
        line = (args["line"] || args[:line]).to_i
        char = (args["character"] || args[:character] || args["col"] || args[:col]).to_i

        return "File path is required" if path.empty?
        return "Line number must be >= 1" if line < 1

        res = @lsp_manager.hover(path, [line - 1, 0].max, [char - 1, 0].max)
        if res[:ok]
          contents = res.dig(:result, "contents")
          if contents.nil? || contents.empty?
            "No hover information available at #{path}:#{line}:#{char}"
          elsif contents.is_a?(Hash) && contents["value"]
            contents["value"]
          elsif contents.is_a?(Array)
            contents.map { |c| c.is_a?(Hash) ? c["value"] : c.to_s }.join("\n")
          else
            contents.to_s
          end
        else
          "LSP Hover failed: #{res[:error]}"
        end
      end
    end

    class LSPDefinitionTool < BaseTool
      def initialize(lsp_manager = nil)
        super(
          name: "lsp_definition",
          description: "Jump to exact type-safe declaration and definition location of a symbol at line/character position via LSP",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to source file" },
              line: { type: "integer", description: "1-based line number" },
              character: { type: "integer", description: "1-based character position" }
            },
            required: %w[file_path line character]
          }
        )
        @lsp_manager = lsp_manager
      end

      def execute(args = {})
        return "LSP manager is not connected" unless @lsp_manager
        return "LSP is currently disabled in configuration (enable via '!lsp on')" unless @lsp_manager.enabled?

        path = (args["file_path"] || args[:file_path]).to_s.strip
        line = (args["line"] || args[:line]).to_i
        char = (args["character"] || args[:character] || args["col"] || args[:col]).to_i

        return "File path is required" if path.empty?
        return "Line number must be >= 1" if line < 1

        res = @lsp_manager.definition(path, [line - 1, 0].max, [char - 1, 0].max)
        if res[:ok]
          result = res[:result]
          if result.nil? || (result.is_a?(Array) && result.empty?)
            "No definition found for symbol at #{path}:#{line}:#{char}"
          else
            locs = Array(result)
            lines = ["Found #{locs.size} definition location(s):"]
            locs.each do |loc|
              uri = loc["uri"] || loc.dig("targetUri")
              clean_file = uri.to_s.sub(%r{^file://}, "")
              range = loc["range"] || loc.dig("targetSelectionRange") || {}
              s_line = (range.dig("start", "line") || 0) + 1
              s_char = (range.dig("start", "character") || 0) + 1
              lines << "  • #{clean_file}:#{s_line}:#{s_char}"
            end
            lines.join("\n")
          end
        else
          "LSP Definition failed: #{res[:error]}"
        end
      end
    end

    class RunTestsTool < BaseTool
      def initialize(adapter_registry, context_index = nil, root_dir: Dir.pwd)
        super(
          name: "run_tests",
          description: "Run the project test suite using the appropriate language adapter",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              language: { type: "string", description: "Language test runner to use (e.g. ruby, go, rust, zig, python, c) (optional)" }
            }
          }
        )
        @adapter_registry = adapter_registry
        @context_index = context_index
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        lang = args["language"] || args[:language]
        unless lang
          langs = @context_index&.languages || []
          lang = langs.first || "ruby"
        end

        adapter = @adapter_registry.get(lang.to_s.downcase)
        return "No adapter available for language '#{lang}'" unless adapter

        res = adapter.run_tests(@root_dir)
        status = res[:ok] ? "PASSED" : "FAILED"
        "Test run [#{status}] (#{res[:duration]}s):\n#{res[:output]}"
      end
    end

    class RunCommandTool < BaseTool
      def initialize(guard:, runner:, root_dir: Dir.pwd)
        super(
          name: "run_command",
          description: "Execute a safe shell command inside the sandbox runner",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "Shell command to run" },
              timeout: { type: "integer", description: "Timeout in seconds (optional, default: 15)" }
            },
            required: ["command"]
          }
        )
        @guard = guard
        @runner = runner
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        cmd = (args["command"] || args[:command]).to_s.strip
        timeout = (args["timeout"] || args[:timeout] || 15).to_i

        @guard.verify_command_safety!(cmd)
        res = @runner.run(cmd, timeout: timeout, chdir: @root_dir)
        status = res[:ok] ? "OK" : "EXIT #{res[:exit_code]}"
        "[#{status}] #{res[:output]}"
      rescue Rubik::Security::BlockedWriteError => e
        "Security blocked: #{e.message}"
      rescue StandardError => e
        "Command error: #{e.message}"
      end
    end

    class ExecReplCommandTool < BaseTool
      def initialize(shell = nil)
        super(
          name: "exec_repl_command",
          description: "Execute an internal Rubik REPL bang command (e.g. !test, !diff, !undo, !context scan, !model set fast, !status, !lint) and return its output",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "The full REPL command string to execute (e.g. '!diff', '!test', '!context scan')" }
            },
            required: ["command"]
          }
        )
        @shell = shell
      end

      def execute(args = {})
        cmd = (args["command"] || args[:command]).to_s.strip
        return "No command provided" if cmd.empty?
        return "REPL shell is not connected" unless @shell

        # Format command with leading ! if missing
        cmd = "!#{cmd}" unless cmd.start_with?("!")

        # Prevent recursive loops of plan/goal inside plan/goal
        if cmd.start_with?("!plan") || cmd.start_with?("!goal")
          return "Nested #{cmd.split.first} invocation inside tool call is blocked."
        end

        captured_out = StringIO.new
        orig_out = @shell.instance_variable_get(:@output)
        @shell.instance_variable_set(:@output, captured_out)

        begin
          @shell.execute_input(cmd)
        ensure
          @shell.instance_variable_set(:@output, orig_out)
        end

        output_str = captured_out.string.strip
        output_str.empty? ? "Command #{cmd} executed with no output." : output_str
      end
    end

    class SynthesizeCommandTool < BaseTool
      def initialize(shell = nil, overlay_storage = nil, guard = nil, legacy_runtime_manager = nil, runtime_manager: nil)
        super(
          name: "synthesize_command",
          description: "Dynamically create and register a new Rubik REPL bang command or tool at runtime (session, project, or global scope)",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Name of the new command without '!' (e.g. 'db_seed', 'benchmark_api')" },
              description: { type: "string", description: "Short description of what the command does for !help" },
              scope: { type: "string", enum: %w[session project global], description: "Storage scope: session (in-memory only), project (.rubik/commands), global (~/.rubik/commands)" },
              code: { type: "string", description: "Ruby handler code: ->(args, out, shell) { ... }" }
            },
            required: %w[name code]
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

        return "Command name cannot be empty" if name.empty?
        return "Handler code cannot be empty" if code.empty?

        # 1. Syntax & Safety Verification in isolated sub-context
        proc_handler = begin
          eval(code)
        rescue SyntaxError, ScriptError, StandardError => e
          return "Syntax error in synthesized code: #{e.message}"
        end

        unless proc_handler.respond_to?(:call)
          return "Code must evaluate to a callable Proc or Lambda (e.g. ->(args, out, shell) { ... })"
        end

        # 2. Persist to storage if scope is project or global
        if %i[project global].include?(scope)
          save_res = @overlay_storage.save_command(name, code, scope: scope, description: description)
          return "Failed to persist command: #{save_res[:error]}" unless save_res[:ok]
        end

        # 3. Register live in REPL shell
        if @shell
          @shell.register_command(name, description: "#{description} [#{scope}]") do |cmd_args|
            out = @shell.instance_variable_get(:@output)
            if proc_handler.arity == 1
              proc_handler.call(cmd_args)
            elsif proc_handler.arity == 2
              proc_handler.call(cmd_args, out)
            else
              proc_handler.call(cmd_args, out, @shell)
            end
          end

          # Register inverse in Runtime Context
          if @runtime_manager&.context
            @runtime_manager.context.on_dispose do
              @shell.unregister_command(name)
            end
          end
        end

        "Successfully synthesized and registered !#{name} [scope: #{scope}]. You can now run it using !#{name} or via exec_repl_command('!#{name}')."
      end
    end

    class SynthesizeToolTool < BaseTool
      def initialize(tool_registry = nil, overlay_storage = nil, guard = nil, legacy_runtime_manager = nil, runtime_manager: nil)
        super(
          name: "synthesize_tool",
          description: "Synthesize, verify, and register a new native function calling tool into the agent's live toolbelt at runtime (session, project, or global scope)",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Name of the new tool (e.g. 'calc_stats', 'inspect_ast_node')" },
              description: { type: "string", description: "Clear explanation of what the tool does for model selection" },
              scope: { type: "string", enum: %w[session project global], description: "Storage scope: session (in-memory only), project (.rubik/tools), global (~/.rubik/tools)" },
              risk: { type: "string", enum: %w[read write execute], description: "Risk level of tool (default: execute)" },
              params_schema: { type: "object", description: "JSON Schema definition of the tool parameters" },
              code: { type: "string", description: "Ruby implementation of tool handler: ->(args) { ... } or class extending Rubik::Tools::BaseTool" },
              test_args: { type: "object", description: "Optional test arguments to perform pre-flight verification in an isolated sandbox" }
            },
            required: %w[name description code]
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

        return "Tool name cannot be empty" if name.empty?
        return "Tool code cannot be empty" if code.empty?

        # 1. Pre-flight Syntax & Sandbox Verification in isolated Context
        tool_instance = nil
        begin
          evaluated = eval(code)
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
                            return "Tool code must evaluate to a callable Proc (->(args) { ... }) or a BaseTool subclass."
                          end

          if test_args
            tool_instance.execute(test_args)
          end
        rescue SyntaxError, ScriptError, StandardError => e
          return "Pre-flight verification failed for tool '#{name}': #{e.message}"
        end

        # 2. Persist to storage if scope is project or global
        if %i[project global].include?(scope)
          save_res = @overlay_storage.save_tool(name, code, scope: scope, description: description, params_schema: schema, risk: risk)
          return "Failed to persist tool: #{save_res[:error]}" unless save_res[:ok]
        end

        # 3. Register live into active tool registry
        if @tool_registry
          @tool_registry.register(tool_instance)

          # Register inverse in Runtime Context
          if @runtime_manager&.context
            @runtime_manager.context.on_dispose do
              @tool_registry.unregister(name)
            end
          end
        end

        "🎉 Successfully synthesized and registered native tool '#{name}' [scope: #{scope}]. It is now immediately available in your active toolbelt for function calling."
      end
    end

    class InspectRuntimeTool < BaseTool
      def initialize(runtime_manager = nil, tool_registry = nil, shell = nil)
        super(
          name: "inspect_runtime",
          description: "Inspect the Spatiotemporal Composability runtime state: active/pending fibers, coeffects, registered services, tools, and commands",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              target: { type: "string", enum: %w[all fibers services tools commands], description: "Component to inspect (default: all)" }
            }
          }
        )
        @runtime_manager = runtime_manager
        @tool_registry = tool_registry
        @shell = shell
      end

      def execute(args = {})
        target = (args["target"] || args[:target] || "all").to_s.downcase

        lines = ["=== Rubik Spatiotemporal Runtime Diagnostics ==="]

        if %w[all services].include?(target) && @runtime_manager
          root_ctx = @runtime_manager.context
          services = root_ctx.instance_variable_get(:@services) || {}
          disposables = root_ctx.instance_variable_get(:@disposables) || []
          lines << "\n[Services / Coeffects Active (#{services.size})]:"
          services.each { |k, v| lines << "  • #{k.to_s.ljust(12)} -> #{v.class}" }
          lines << "  (LIFO Accumulator Depth: #{disposables.size} inverse disposables)"
        end

        if %w[all fibers].include?(target) && @runtime_manager
          active = @runtime_manager.active_fibers
          pending = @runtime_manager.pending_fibers
          failed = @runtime_manager.fibers.values.select { |f| f.state == :failed }
          lines << "\n[Fibers (#{active.size} Active, #{pending.size} Pending, #{failed.size} Failed)]:"
          active.each { |f| lines << "  🟢 ACTIVE : #{f.name} (injects: #{f.inject.join(', ')})" }
          pending.each do |f|
            missing = f.inject.reject { |dep| @runtime_manager.context.has?(dep) }
            lines << "  ⏳ PENDING: #{f.name} (waiting on: #{missing.join(', ')})"
          end
          failed.each { |f| lines << "  🔴 FAILED : #{f.name} (error: #{f.last_error&.message})" }
        end

        if %w[all tools].include?(target) && @tool_registry
          tools = @tool_registry.list
          lines << "\n[Tool Registry (#{tools.size} Registered Tools)]:"
          tools.each { |t| lines << "  ⚙ #{t.name.ljust(22)} [#{t.risk}] - #{t.description[0..60]}" }
        end

        if %w[all commands].include?(target) && @shell
          cmds = @shell.commands
          lines << "\n[REPL Bang Commands (#{cmds.size} Registered)]:"
          cmds.sort.each { |name, meta| lines << "  !#{name.ljust(16)} : #{meta[:description]}" }
        end

        lines.join("\n")
      end
    end

    class ProvideServiceTool < BaseTool
      def initialize(runtime_manager = nil)
        super(
          name: "provide_service",
          description: "Provide a runtime service/coeffect into the root context, triggering reactive state transitions (Pending -> Active) for dependent fibers",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Service/coeffect name (e.g. 'database', 'lsp_client', 'mock_api')" },
              value: { type: "string", description: "Service description or initialization payload" }
            },
            required: ["name"]
          }
        )
        @runtime_manager = runtime_manager
      end

      def execute(args = {})
        name = (args["name"] || args[:name]).to_s.strip.downcase
        val = args["value"] || args[:value] || true
        return "Service name cannot be empty" if name.empty?
        return "Runtime manager is not available" unless @runtime_manager

        @runtime_manager.provide(name, val)
        active_count = @runtime_manager.active_fibers.size
        pending_count = @runtime_manager.pending_fibers.size

        "Service '#{name}' provided to runtime context. Reconciled fibers: #{active_count} Active, #{pending_count} Pending."
      end
    end

    class ApplyBufferTool < BaseTool
      def initialize(buffer_manager = nil, shell = nil)
        super(
          name: "apply_buffer",
          description: "Persist all pending in-memory file buffer modifications to disk immediately",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              reason: { type: "string", description: "Optional explanation of why buffer is being applied (e.g. 'prior to running tests')" }
            }
          }
        )
        @buffer_manager = buffer_manager
        @shell = shell
      end

      def execute(args = {})
        return "Buffer manager is not connected" unless @buffer_manager

        if @buffer_manager.dirty?
          applied = @buffer_manager.apply!
          @shell&.sync_context_and_ast(applied)
          "Successfully applied #{applied.size} modified file(s) to disk: #{applied.join(', ')}"
        else
          "No unapplied buffer changes to write (buffer is clean)."
        end
      end
    end

    class FinishTool < BaseTool
      def initialize
        super(
          name: "finish",
          description: "Signal task completion with final message",
          risk: :read,
          params_schema: { type: "object", properties: { message: { type: "string" } } }
        )
      end

      def execute(args = {})
        args["message"] || args[:message] || "Task finished"
      end
    end
  end
end
