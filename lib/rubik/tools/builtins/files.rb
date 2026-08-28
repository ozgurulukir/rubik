# frozen_string_literal: true

require_relative "../base"

module Rubik
  module Tools
    class ReadFileTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "read_file",
          aliases: %w[view_file read],
          description: "Read content of a file from buffer or disk (optional 1-based offset and line limit for paging)",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              path: { type: "string" },
              offset: { type: "integer", description: "1-based line number to start reading from (optional)" },
              limit: { type: "integer", description: "Maximum number of lines to return (optional)" }
            },
            required: ["path"]
          }
        )
        @buffer_manager = buffer_manager
      end

      def execute(args = {})
        path = args["path"] || args[:path]
        content = @buffer_manager.read(path)
        return "File not found: #{path}" unless content

        offset = (args["offset"] || args[:offset]).to_i
        limit = (args["limit"] || args[:limit]).to_i
        return content if offset <= 1 && limit <= 0

        # Paging contract (models expect offset/limit from prior tool
        # training): slice silently ignoring them makes the model re-read
        # the same file hunting for lines it already received.
        lines = content.lines
        start_idx = [offset, 1].max - 1
        slice = limit.positive? ? lines[start_idx, limit] || [] : lines[start_idx..] || []
        header = "[lines #{start_idx + 1}-#{start_idx + slice.length} of #{lines.length} total]\n"
        slice.empty? ? "No content at offset #{offset} (file has #{lines.length} lines)." : header + slice.join
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
              path: { type: "string", description: "Subdirectory or path prefix relative to the project root (e.g. 'lib', 'src'). Absolute paths are converted automatically. (optional)" },
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

        filter, error = BaseTool.normalize_path_filter(path_filter, @root_dir)
        return error if error

        files = idx.files.empty? ? idx.full_scan : idx.files
        file_list = files.keys

        file_list = file_list.select { |f| f.start_with?(filter) } unless filter.empty?
        file_list = file_list.select { |f| f.end_with?(ext_filter) } if ext_filter && !ext_filter.empty?

        if file_list.empty?
          BaseTool.no_match_message(filter)
        else
          "Found #{file_list.size} file(s):\n#{file_list.first(50).map { |f| " - #{f}" }.join("\n")}"
        end
      end
    end
  end
end
