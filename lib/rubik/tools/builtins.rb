# frozen_string_literal: true

require_relative "base"
require_relative "../runtime"

module Rubik
  module Tools
    class ReadFileTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "read_file",
          aliases: %w[view_file read],
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
          aliases: %w[create_file edit_file save_file],
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
      def initialize(context_index = nil, root_dir: Dir.pwd, runtime_context: nil, context: nil)
        super(
          name: "list_files",
          aliases: %w[list_directory list_dir ls],
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
        @runtime_context = runtime_context || context
        @root_dir = File.expand_path(root_dir)
      end

      def context_index
        @runtime_context&.get("context_index") || @runtime_context&.get("index") || @context_index
      end

      def execute(args = {})
        path_filter = args["path"] || args[:path]
        ext_filter = args["extension"] || args[:extension]

        idx = context_index
        return "Context index is not available." unless idx

        files = idx.files.empty? ? idx.full_scan : idx.files
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

    class GrepSearchTool < BaseTool
      def initialize(buffer_manager = nil, context_index = nil, root_dir: Dir.pwd, runtime_context: nil, context: nil)
        super(
          name: "grep_search",
          aliases: %w[search_code grep search_files],
          description: "Search for exact string or regular expression across project files with line numbers and matched content",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              query: { type: "string", description: "Text or regex pattern to search for" },
              path: { type: "string", description: "Subdirectory or file path filter (optional)" },
              extension: { type: "string", description: "File extension filter, e.g. .rb, .go (optional)" },
              case_sensitive: { type: "boolean", description: "Whether search is case-sensitive (optional, default: false)" },
              max_results: { type: "integer", description: "Maximum number of matched lines to return (optional, default: 50)" }
            },
            required: ["query"]
          }
        )
        @buffer_manager = buffer_manager
        @context_index = context_index
        @runtime_context = runtime_context || context
        @root_dir = File.expand_path(root_dir)
      end

      def context_index
        @runtime_context&.get("context_index") || @runtime_context&.get("index") || @context_index
      end

      def buffer_manager
        @runtime_context&.get("buffer") || @buffer_manager
      end

      def execute(args = {})
        query = (args["query"] || args[:query]).to_s.strip
        return "Query parameter required" if query.empty?

        path_filter = (args["path"] || args[:path]).to_s.strip
        ext_filter = (args["extension"] || args[:extension]).to_s.strip
        case_sensitive = args["case_sensitive"] || args[:case_sensitive] || false
        max_results = (args["max_results"] || args[:max_results] || 50).to_i
        max_results = 50 if max_results <= 0

        # Collect project files from context index / disk
        idx = context_index
        files = if idx
                  idx.files.empty? ? idx.full_scan : idx.files
                else
                  Rubik::Context::Scanner.new(root_dir: @root_dir).scan
                end

        buf = buffer_manager
        all_file_keys = files.keys
        if buf&.dirty_files
          all_file_keys = (all_file_keys + buf.dirty_files.keys).uniq
        end

        # Apply path filter
        if !path_filter.empty?
          normalized = path_filter.sub(%r{^\./}, "")
          all_file_keys = all_file_keys.select do |f|
            f == normalized || f.start_with?(normalized.end_with?("/") ? normalized : "#{normalized}/") || f.start_with?(normalized)
          end
        end

        # Apply extension filter
        if !ext_filter.empty?
          ext = ext_filter.start_with?(".") ? ext_filter : ".#{ext_filter}"
          all_file_keys = all_file_keys.select { |f| f.end_with?(ext) }
        end

        regex = begin
          flags = case_sensitive ? nil : Regexp::IGNORECASE
          Regexp.new(query, flags)
        rescue RegexpError
          flags = case_sensitive ? nil : Regexp::IGNORECASE
          Regexp.new(Regexp.escape(query), flags)
        end

        matches = []
        all_file_keys.sort.each do |f|
          content = if @buffer_manager
                      @buffer_manager.read(f)
                    else
                      full_p = File.expand_path(f, @root_dir)
                      File.exist?(full_p) ? File.read(full_p) : nil
                    end

          next unless content.is_a?(String)
          next if content.include?("\x00") # skip binary files

          content.lines.each_with_index do |line_content, idx|
            if regex.match?(line_content)
              matches << {
                file: f,
                line: idx + 1,
                content: line_content.chomp
              }
              break if matches.size >= max_results
            end
          end

          break if matches.size >= max_results
        end

        if matches.empty?
          "No matching lines found for '#{query}'."
        else
          lines = ["Found #{matches.size} match(es) for '#{query}':"]
          matches.each do |m|
            lines << "#{m[:file]}:#{m[:line]}: #{m[:content]}"
          end
          lines.join("\n")
        end
      end
    end

    class SearchSymbolsTool < BaseTool
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(
          name: "search_symbols",
          aliases: %w[find_symbols symbols],
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
        @runtime_context = runtime_context || context
      end

      def ast_graph
        @runtime_context&.get("ast_graph") || @runtime_context&.get("ast") || @ast_graph
      end

      def execute(args = {})
        query = (args["query"] || args[:query]).to_s.strip
        return "Query parameter required" if query.empty?

        graph = ast_graph
        return "AST graph is not available" unless graph

        if args["smart_context"] || args[:smart_context]
          ctx = graph.smart_context_for(query)
          return ctx.empty? ? "No smart context found for '#{query}'." : ctx
        end

        matches = graph.symbols.values.select do |sym|
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
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(
          name: "get_outline",
          aliases: %w[file_outline outline],
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
        @runtime_context = runtime_context || context
      end

      def ast_graph
        @runtime_context&.get("ast_graph") || @runtime_context&.get("ast") || @ast_graph
      end

      def execute(args = {})
        path = (args["file_path"] || args[:file_path] || args["path"] || args[:path]).to_s.strip
        return "File path is required" if path.empty?

        graph = ast_graph
        return "AST graph is not available" unless graph

        graph.outline_for(path)
      end
    end

    class FindReferencesTool < BaseTool
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(
          name: "find_references",
          aliases: %w[references get_callers],
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
        @runtime_context = runtime_context || context
      end

      def ast_graph
        @runtime_context&.get("ast_graph") || @runtime_context&.get("ast") || @ast_graph
      end

      def execute(args = {})
        sym_name = (args["symbol_name"] || args[:symbol_name] || args["symbol"] || args[:symbol]).to_s.strip
        return "Symbol name is required" if sym_name.empty?

        graph = ast_graph
        return "AST graph is not available" unless graph

        callers = graph.callers_of(sym_name)
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
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(
          name: "get_symbol",
          aliases: %w[get_definition symbol_info],
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
        @runtime_context = runtime_context || context
      end

      def ast_graph
        @runtime_context&.get("ast_graph") || @runtime_context&.get("ast") || @ast_graph
      end

      def execute(args = {})
        sym_name = (args["symbol_name"] || args[:symbol_name] || args["symbol"] || args[:symbol]).to_s.strip
        return "Symbol name is required" if sym_name.empty?

        graph = ast_graph
        return "AST graph is not available" unless graph

        info = graph.symbol_definition(sym_name)
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
          aliases: %w[get_diagnostics diagnostics],
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
          aliases: %w[get_hover hover],
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
          aliases: %w[goto_definition definition],
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
          aliases: %w[test run_test_suite],
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
          aliases: %w[bash sh execute_command cmd],
          description: "Execute a safe shell command inside the sandbox runner in the project working directory (do not use cd)",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "Shell command to run directly in the project directory" },
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
      REDIRECT_MAP = {
        "test"    => "run_tests",
        "sh"      => "run_command",
        "read"    => "read_file",
        "write"   => "write_file",
        "apply"   => "apply_buffer",
        "symbols" => "search_symbols",
        "outline" => "get_outline",
        "refs"    => "find_references",
        "ast"     => "get_symbol / get_outline"
      }.freeze

      def initialize(shell = nil)
        super(
          name: "exec_repl_command",
          aliases: %w[repl_command exec_repl repl],
          description: "Execute internal Rubik REPL configuration commands (!config, !model, !undo, !rollback, !runtime, !fibers, !services). Do NOT use this tool for reading files, writing code, or running tests—use direct tools (read_file, write_file, run_tests) instead.",
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

        base_cmd = cmd.split.first.to_s.downcase.delete_prefix("!")

        if REDIRECT_MAP.key?(base_cmd)
          return "Notice: Please use native tool '#{REDIRECT_MAP[base_cmd]}' directly instead of exec_repl_command('#{cmd}'). REPL commands are not suitable for autonomous tool invocation for this action."
        end

        unless @shell.commands.key?(base_cmd)
          return "Unknown REPL command '!#{base_cmd}'. Rubik does not have a '!#{base_cmd}' command. To explore files, read code, or perform a review, use direct tools ('list_files', 'read_file', 'search_symbols', 'get_outline') instead of REPL commands."
        end

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
          aliases: %w[create_command add_command],
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
          @shell.register_command(name, description: "#{description} [#{scope}]", custom: true) do |cmd_args|
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
          aliases: %w[create_tool add_tool],
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
          aliases: %w[runtime_status inspect_fibers],
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
          aliases: %w[register_service add_service],
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
          aliases: %w[save_buffer commit_changes save],
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

    class RepairRuntimeTool < BaseTool
      def initialize(runtime_manager: nil, lsp_manager: nil, adapter_registry: nil, overlay_storage: nil, config: nil, root_dir: Dir.pwd)
        super(
          name: "repair_runtime_service",
          aliases: %w[fix_service repair_lsp repair_runner repair_runtime],
          description: "Diagnose, adapt, or synthesize a replacement command/adapter for a failing runtime component (LSP, test runner, linter, or shell command) with pre-flight verification in an isolated sub-context",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              target: {
                type: "string",
                enum: %w[lsp test_runner linter command],
                description: "Runtime component type to repair or adapt"
              },
              language_or_type: {
                type: "string",
                description: "Language or service identifier (e.g., 'ruby', 'python', 'rust', 'go', 'zig', 'c', 'bash')"
              },
              proposed_command: {
                type: "string",
                description: "Replacement or custom command string (optional, probed automatically if auto_probe: true)"
              },
              auto_probe: {
                type: "boolean",
                description: "Whether to automatically probe system binaries and candidate commands (default: true)"
              }
            },
            required: %w[target language_or_type]
          }
        )
        @runtime_manager = runtime_manager
        @lsp_manager = lsp_manager
        @adapter_registry = adapter_registry
        @overlay_storage = overlay_storage
        @config = config
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        target = (args["target"] || args[:target]).to_s.downcase.strip
        lang = (args["language_or_type"] || args[:language_or_type]).to_s.downcase.strip
        proposed_cmd = (args["proposed_command"] || args[:proposed_command]).to_s.strip
        auto_probe = args["auto_probe"].nil? ? (args[:auto_probe].nil? ? true : args[:auto_probe]) : args["auto_probe"]

        return "Target and language_or_type must be provided" if target.empty? || lang.empty?

        # 1. Automatic Probing if proposed_cmd is not specified or auto_probe is requested
        if proposed_cmd.empty? && auto_probe
          candidate = case target
                      when "lsp"
                        Rubik::Runtime::Discovery.probe_lsp(lang, root_dir: @root_dir)
                      when "test_runner"
                        Rubik::Runtime::Discovery.discover_test_runners(root_dir: @root_dir, lang: lang).first
                      when "linter"
                        Rubik::Runtime::Discovery.discover_formatters(root_dir: @root_dir, lang: lang).first
                      when "command"
                        Rubik::Runtime::Discovery.binary_available?(lang) ? lang : nil
                      end

          if candidate
            proposed_cmd = candidate
          else
            candidates = case target
                         when "lsp" then Rubik::Runtime::Discovery.lsp_candidates(lang)
                         when "test_runner" then Rubik::Runtime::Discovery.test_runner_candidates(lang, root_dir: @root_dir)
                         when "linter" then Rubik::Runtime::Discovery::FORMATTER_CANDIDATES[lang] || []
                         else []
                         end
            cand_str = candidates.empty? ? "none" : candidates.join(", ")
            return "Auto-probe failed to discover any installed candidate for #{target} (#{lang}). Candidates checked: [#{cand_str}]. Please provide a specific `proposed_command`."
          end
        end

        return "No command provided or discovered for #{target} (#{lang})" if proposed_cmd.empty?

        # 2. Pre-flight Verification in Isolated Sub-Context (ctx.extend())
        root_ctx = @runtime_manager&.context || Rubik::Runtime::Context.new
        sub_ctx = root_ctx.extend

        verified = false
        error_diagnostic = nil

        begin
          case target
          when "lsp"
            client = Rubik::LSP::Client.new(lang, root_dir: @root_dir, server_cmd: proposed_cmd)
            if client.available?
              sub_ctx.provide("lsp_probe:#{lang}", client)
              verified = true
            else
              error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
                cmd: proposed_cmd,
                exit_code: 127,
                stderr: "Pre-flight check failed: LSP binary '#{client.binary_name}' not available on system"
              )
            end
          when "test_runner"
            if Rubik::Runtime::Discovery.binary_available?(proposed_cmd)
              sub_ctx.provide("runner_probe:#{lang}", proposed_cmd)
              verified = true
            else
              error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
                cmd: proposed_cmd,
                exit_code: 127,
                stderr: "Pre-flight check failed: Test runner executable not found in PATH"
              )
            end
          when "linter"
            if Rubik::Runtime::Discovery.binary_available?(proposed_cmd)
              sub_ctx.provide("linter_probe:#{lang}", proposed_cmd)
              verified = true
            else
              error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
                cmd: proposed_cmd,
                exit_code: 127,
                stderr: "Pre-flight check failed: Linter/formatter executable not found in PATH"
              )
            end
          when "command"
            if Rubik::Runtime::Discovery.binary_available?(proposed_cmd)
              sub_ctx.provide("command_probe:#{lang}", proposed_cmd)
              verified = true
            else
              error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
                cmd: proposed_cmd,
                exit_code: 127,
                stderr: "Pre-flight check failed: Command executable not found in PATH"
              )
            end
          else
            error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
              cmd: proposed_cmd,
              exit_code: 1,
              stderr: "Unknown target component type: #{target}"
            )
          end
        rescue StandardError => e
          error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
            cmd: proposed_cmd,
            exit_code: 1,
            stderr: "Exception during pre-flight sandbox check: #{e.message}"
          )
        ensure
          sub_ctx.dispose
        end

        unless verified
          return "Verification failed for #{target} (#{lang}):\n#{error_diagnostic&.format_for_llm}"
        end

        # 3. Live Context Promotion & Subsystem Configuration (Zero-Downtime Hot Swapping)
        case target
        when "lsp"
          @config&.set("lsp.servers.#{lang}", proposed_cmd, persist: :project)
          if @lsp_manager
            @lsp_manager.stop_client(lang)
            @lsp_manager.start_client(lang)
            active_client = @lsp_manager.client_for(lang)
            root_ctx.provide("lsp:#{lang}", active_client) if active_client
          else
            root_ctx.provide("lsp:#{lang}", proposed_cmd)
          end
        when "test_runner"
          @config&.set("test.runners.#{lang}", proposed_cmd, persist: :project)
          if @adapter_registry
            adapter = @adapter_registry.get(lang)
            adapter.custom_test_cmd = proposed_cmd if adapter
          end
          root_ctx.provide("runner:#{lang}", proposed_cmd)
        when "linter"
          @config&.set("linter.commands.#{lang}", proposed_cmd, persist: :project)
          if @adapter_registry
            adapter = @adapter_registry.get(lang)
            adapter.custom_format_cmd = proposed_cmd if adapter
          end
          root_ctx.provide("linter:#{lang}", proposed_cmd)
        when "command"
          root_ctx.provide("command:#{lang}", proposed_cmd)
        end

        "✨ Successfully verified and promoted runtime service for #{target} (#{lang}): '#{proposed_cmd}'. Service is now active and hot-swapped in the live context with zero downtime."
      end
    end

    class FinishTool < BaseTool
      def initialize
        super(
          name: "finish",
          aliases: %w[complete done task_complete exit],
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
