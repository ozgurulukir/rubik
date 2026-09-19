# frozen_string_literal: true

require_relative "../base"
require_relative "../../coeffects"
require_relative "../output"
require_relative "../diagnostic_reporter"
require_relative "../fuzzy_matcher"
require_relative "../../buffer/path_validator"

module Rubik
  module Tools
    class ReadFileTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "read_file",
          aliases: ["view_file", "read"],
          description: "Read content of a file from buffer or disk with 1-based line numbers (optional 1-based offset and line limit for paging)",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              path: { type: "string", description: "Path to the file to read" },
              offset: { type: "integer", description: "1-based line number to start reading from (optional)" },
              limit: { type: "integer", description: "Maximum number of lines to return (optional)" },
              from_disk: { type: "boolean", description: "Read current disk content without modifying in-memory buffer" },
              reload: { type: "boolean", description: "Discard dirty buffer and reload from disk (resets pending changes)" }
            },
            required: ["path"]
          }
        )
        @buffer_manager = buffer_manager
      end

      def execute(args = {})
        path = (args["path"] || args[:path]).to_s.strip
        if path =~ %r{\Arubik://subagent/([^/]+)/transcript(?:\.jsonl)?(?:#.*)?\z}i
          sub_id = ::Regexp.last_match(1)
          path = File.join(".rubik", "subagents", sub_id, "transcript.jsonl")
        elsif path.start_with?("file://")
          clean = path.sub(%r{\Afile://}, "")
          path = clean.sub(%r{\A/([A-Za-z]:)}, '\1')
        end

        content = if args["reload"] == true || args[:reload] == true
                    @buffer_manager.read(path, reload: true)
                  elsif args["from_disk"] == true || args[:from_disk] == true
                    @buffer_manager.read(path, from_disk: true)
                  else
                    @buffer_manager.read(path)
                  end

        unless content
          known_files = @buffer_manager.respond_to?(:all_files) ? @buffer_manager.all_files : []
          candidates = FuzzyMatcher.best_matches(File.basename(path), known_files.map { |f| File.basename(f) })
          return ToolOutput.error(DiagnosticReporter.render_file_not_found(path, candidates: candidates))
        end

        offset = (args["offset"] || args[:offset]).to_i
        limit = (args["limit"] || args[:limit]).to_i
        lines = content.lines
        return "[empty file (0 lines)]" if lines.empty?

        start_idx = [offset, 1].max - 1
        slice = limit.positive? ? (lines[start_idx, limit] || []) : (lines[start_idx..] || [])
        return ToolOutput.error("No content at offset #{offset} (file has #{lines.length} lines).") if slice.empty?

        numbered = slice.each_with_index.map { |line, idx| "#{start_idx + idx + 1}: #{line}" }.join
        offset > 1 || limit.positive? ? "[lines #{start_idx + 1}-#{start_idx + slice.length} of #{lines.length} total]\n#{numbered}" : numbered
      rescue Errno::EACCES => e
        ToolOutput.error(DiagnosticReporter.render_permission_denied(path, operation: "read", reason: e.message))
      rescue Rubik::Buffer::InvalidPathError
        ToolOutput.error(DiagnosticReporter.render_traversal_blocked(path))
      end
    end

    class WriteFileTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "write_file",
          aliases: ["create_file", "save_file", "overwrite_file"],
          description: "Write full content to the in-memory buffer (does not write to disk until apply_buffer is called). " \
                       "For surgical edits to existing files, use replace_file_content instead. " \
                       "Use apply_buffer to persist the buffer to disk before running tests or tests will not see your changes.",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              path: { type: "string", description: "File path relative to the project root (e.g. 'lib/app.rb', 'Gemfile')" },
              content: { type: "string", description: "Full file content to write (overwrites entire file)" }
            },
            required: ["path", "content"]
          }
        )
        @buffer_manager = buffer_manager
      end

      def execute(args = {})
        path = (args["path"] || args[:path]).to_s.strip
        content = args["content"] || args[:content]

        return ToolOutput.error("Error: `path` parameter is required.") if path.empty?
        unless Rubik::Buffer::PathValidator.valid?(path)
          return ToolOutput.error("Error: Invalid file path '#{path}'. Path must be a valid file path " \
                                  "relative to the project root (e.g. 'lib/app.rb', 'src/main.go', 'Gemfile').")
        end

        begin
          @buffer_manager.write(path, content, reset_baseline: true)
        rescue ArgumentError
          @buffer_manager.write(path, content)
        end
        "Successfully wrote to in-memory buffer: #{path}"
      rescue Errno::EACCES => e
        ToolOutput.error(DiagnosticReporter.render_permission_denied(path, operation: "write", reason: e.message))
      rescue Rubik::Buffer::InvalidPathError
        ToolOutput.error(DiagnosticReporter.render_traversal_blocked(path))
      end
    end

    class ListFilesTool < BaseTool
      # Declared coeffects: hidden from schemas (PENDING) until satisfied (AGENTS.md §2).
      REQUIRES = [Rubik::Coeffects::CONTEXT_INDEX].freeze

      def initialize(context_index = nil, root_dir: Dir.pwd, runtime_context: nil, context: nil)
        super(
          name: "list_files",
          aliases: ["list_directory", "list_dir", "ls"],
          description: "List project files matching an optional path prefix or extension filter. " \
                       "Returns at most 50 files; narrow the query with 'path' and 'extension' for larger trees.",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              path: { type: "string",
                      description: "Subdirectory or path prefix relative to the project root (e.g. 'lib', 'src'). " \
                                   "Absolute paths are converted automatically. (optional)" },
              extension: { type: "string", description: "File extension filter, e.g. .rb, .go, .zig (optional)" }
            }
          }
        )
        @context_index = context_index
        @runtime_context = runtime_context || context
        @root_dir = File.expand_path(root_dir)
      end

      def context_index
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::CONTEXT_INDEX, @context_index)
      end

      def execute(args = {})
        path_filter = args["path"] || args[:path]
        ext_filter = args["extension"] || args[:extension]
        idx = context_index
        return ToolOutput.error("Context index is not available. Run '!context scan' or restart the session to build it.") unless idx

        filter, error = BaseTool.normalize_path_filter(path_filter, @root_dir)
        if error
          allowed = [{ path: @root_dir, primary: true }]
          idx.additional_roots.each { |r| allowed << { path: r, primary: false } } if idx.respond_to?(:additional_roots)
          return ToolOutput.error(DiagnosticReporter.render_traversal_blocked(path_filter, allowed_roots: allowed))
        end

        files = idx.files.empty? ? idx.full_scan : idx.files
        file_list = files.keys
        file_list = file_list.select { |f| f.start_with?(filter) } unless filter.empty?
        file_list = file_list.select { |f| f.end_with?(ext_filter) } if ext_filter && !ext_filter.empty?

        return BaseTool.no_match_message(filter) if file_list.empty?

        "Found #{file_list.size} file(s):\n#{file_list.first(50).map { |f| " - #{f}" }.join("\n")}"
      rescue Errno::EACCES => e
        ToolOutput.error(DiagnosticReporter.render_permission_denied(path_filter || @root_dir, operation: "read", reason: e.message))
      end
    end

    # Surgical, targeted chunk replacement tool for frontier coding models (Plan 56).
    class ReplaceFileContentTool < BaseTool
      def initialize(buffer_manager)
        super(
          name: "replace_file_content",
          aliases: ["edit_file", "edit_chunk", "str_replace", "patch_file"],
          description: "Replace an exact chunk of code within an existing file. Requires exact verbatim matching of target_content " \
                       "(including whitespace and indentation). Optional start_line and end_line narrow the search range.",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              path: { type: "string", description: "Path to the file to edit" },
              target_content: { type: "string", description: "The exact contiguous block of code/text to replace (must match verbatim)" },
              replacement_content: { type: "string", description: "The new replacement text to insert in place of target_content" },
              start_line: { type: "integer", description: "1-based starting line number to restrict search scope (optional)" },
              end_line: { type: "integer", description: "1-based ending line number to restrict search scope (optional)" },
              allow_multiple: { type: "boolean",
                                description: "If true, replaces all occurrences. " \
                                             "If false, fails safely when multiple matches exist (optional, default: false)" }
            },
            required: ["path", "target_content", "replacement_content"]
          }
        )
        @buffer_manager = buffer_manager
      end

      def execute(args = {})
        path = (args["path"] || args[:path]).to_s.strip
        target = args["target_content"] || args[:target_content] ||
                 args["old_content"] || args[:old_content] ||
                 args["old_str"] || args[:old_str] ||
                 args["target"] || args[:target]
        replacement = args["replacement_content"] || args[:replacement_content] ||
                      args["new_content"] || args[:new_content] ||
                      args["new_str"] || args[:new_str] ||
                      args["replacement"] || args[:replacement]
        start_line = args["start_line"] || args[:start_line]
        end_line = args["end_line"] || args[:end_line]
        allow_multiple = args["allow_multiple"] == true || args[:allow_multiple] == true

        return ToolOutput.error("Error: `path` parameter is required.") if path.empty?
        return ToolOutput.error("Error: `target_content` parameter is required.") if target.nil?
        return ToolOutput.error("Error: `target_content` cannot be empty.") if target.to_s.empty?
        return ToolOutput.error("Error: `replacement_content` parameter is required.") if replacement.nil?

        content = @buffer_manager.read(path)
        unless content
          known_files = (@buffer_manager.respond_to?(:all_files) ? @buffer_manager.all_files : [])
          candidates = FuzzyMatcher.best_matches(File.basename(path), known_files.map { |f| File.basename(f) })
          return ToolOutput.error(DiagnosticReporter.render_file_not_found(path, candidates: candidates))
        end

        has_crlf = content.to_s.include?("\r\n")
        norm_file = content.to_s.gsub("\r\n", "\n")
        norm_target = target.to_s.gsub("\r\n", "\n")
        norm_replacement = replacement.to_s.gsub("\r\n", "\n")

        if start_line || end_line
          perform_scoped_replace(path, norm_file, norm_target, norm_replacement, start_line, end_line, allow_multiple, has_crlf)
        else
          perform_full_replace(path, norm_file, norm_target, norm_replacement, allow_multiple, has_crlf)
        end
      rescue Errno::EACCES => e
        ToolOutput.error(DiagnosticReporter.render_permission_denied(path, operation: "write", reason: e.message))
      rescue Rubik::Buffer::InvalidPathError
        ToolOutput.error(DiagnosticReporter.render_traversal_blocked(path))
      end

      private

      def perform_scoped_replace(path, norm_file, norm_target, norm_replacement, start_line, end_line, allow_multiple, has_crlf)
        s_line = [start_line.to_i, 1].max
        e_line = end_line ? end_line.to_i : norm_file.lines.size
        s_line, e_line = e_line, s_line if s_line > e_line

        lines = norm_file.lines
        slice_start_idx = s_line - 1
        slice_len = [e_line - s_line + 1, 0].max
        slice_text = lines[slice_start_idx, slice_len]&.join || ""
        match_count = slice_text.scan(norm_target).size

        if match_count.zero?
          closest = FuzzyMatcher.find_closest_subsequence(norm_target, slice_text)
          adjusted_range = closest ? ((s_line + closest[:range].begin - 1)..(s_line + closest[:range].end - 1)) : nil
          return ToolOutput.error(DiagnosticReporter.render_target_not_found(
                                    path, norm_target, closest_snippet: closest&.fetch(:snippet, nil),
                                                       closest_range: adjusted_range, similarity: closest&.fetch(:similarity, nil),
                                                       start_line: s_line, end_line: e_line
                                  ))
        end

        if match_count > 1 && !allow_multiple
          occurrences = find_line_occurrences(slice_text, norm_target, line_offset: s_line)
          return ToolOutput.error(DiagnosticReporter.render_target_not_unique(path, norm_target, match_count, occurrences))
        end

        new_slice = allow_multiple ? slice_text.gsub(norm_target) { norm_replacement } : slice_text.sub(norm_target) { norm_replacement }
        pre_text = lines[0...slice_start_idx]&.join || ""
        post_text = lines[(slice_start_idx + slice_len)..]&.join || ""
        final_content = "#{pre_text}#{new_slice}#{post_text}"
        final_content = final_content.gsub("\n", "\r\n") if has_crlf && !final_content.include?("\r\n")

        @buffer_manager.write(path, final_content)
        "Successfully replaced content in in-memory buffer: #{path} (scoped to lines #{s_line}..#{e_line})"
      end

      def perform_full_replace(path, norm_file, norm_target, norm_replacement, allow_multiple, has_crlf)
        match_count = norm_file.scan(norm_target).size

        if match_count.zero?
          closest = FuzzyMatcher.find_closest_subsequence(norm_target, norm_file)
          return ToolOutput.error(DiagnosticReporter.render_target_not_found(
                                    path, norm_target, closest_snippet: closest&.fetch(:snippet, nil),
                                                       closest_range: closest&.fetch(:range, nil), similarity: closest&.fetch(:similarity, nil)
                                  ))
        end

        if match_count > 1 && !allow_multiple
          occurrences = find_line_occurrences(norm_file, norm_target, line_offset: 1)
          return ToolOutput.error(DiagnosticReporter.render_target_not_unique(path, norm_target, match_count, occurrences))
        end

        final_content = allow_multiple ? norm_file.gsub(norm_target) { norm_replacement } : norm_file.sub(norm_target) { norm_replacement }
        first_occ_idx = norm_file.index(norm_target)
        first_occ_line = first_occ_idx ? (norm_file[0...first_occ_idx].count("\n") + 1) : 1
        rep_lines_size = norm_replacement.lines.size
        end_mod_line = [first_occ_line + rep_lines_size - 1, first_occ_line].max

        final_content = final_content.gsub("\n", "\r\n") if has_crlf && !final_content.include?("\r\n")
        @buffer_manager.write(path, final_content)
        "Successfully replaced content in in-memory buffer: #{path} (modified lines #{first_occ_line}..#{end_mod_line})"
      end

      def find_line_occurrences(text, target, line_offset: 1)
        occurrences = []
        current_pos = 0
        while (idx = text.index(target, current_pos))
          occurrences << (text[0...idx].count("\n") + line_offset)
          current_pos = idx + target.length
        end
        occurrences.uniq
      end
    end
  end
end
