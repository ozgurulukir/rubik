# frozen_string_literal: true

require_relative "base"

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
