# frozen_string_literal: true

require_relative "../base"
require_relative "../../coeffects"
require_relative "../output"
require_relative "../native_search"
require_relative "../diagnostic_reporter"

module Rubik
  module Tools
    class GrepSearchTool < BaseTool
      MAX_LINE_CHARS = 500
      MAX_OUTPUT_CHARS = 30_000

      DECLARATION = Declaration.new(
        name: "grep_search", aliases: ["search_code", "grep", "search_files"],
        description: "Search for exact string or regular expression across project files with line numbers and matched content",
        risk: :read, archetypes: [:research, :coder],
        params_schema: {
          type: "object",
          properties: {
            query: { type: "string", description: "Text or regex pattern to search for" },
            path: { type: "string",
                    description: "Subdirectory or file path relative to the project root (e.g. 'lib', 'src/main.go'). " \
                                 "Absolute paths are converted automatically. (optional)" },
            extension: { type: "string", description: "File extension filter, e.g. .rb, .go (optional)" },
            case_sensitive: { type: "boolean", description: "Whether search is case-sensitive (optional, default: false)" },
            max_results: { type: "integer", description: "Maximum number of matched lines to return (optional, default: 50)" }
          },
          required: ["query"]
        }
      )
      def initialize(buffer_manager = nil, context_index = nil, root_dir: Dir.pwd, runtime_context: nil, context: nil, config: nil)
        super(DECLARATION)
        @buffer_manager = buffer_manager
        @context_index = context_index
        @runtime_context = runtime_context || context
        @config = config
        @root_dir = File.expand_path(root_dir)
      end

      def context_index
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::CONTEXT_INDEX, @context_index)
      end

      def buffer_manager
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::BUFFER_MANAGER, @buffer_manager)
      end

      def execute(args = {})
        # Scrub before strip-driven string ops and result interpolation: an
        # invalid-UTF-8 query (model transcription artifact) must not raise
        # or leak broken bytes into the rendered tool output.
        query = Rubik::Platform.safe_utf8((args["query"] || args[:query]).to_s).strip
        return ToolOutput.error("Query parameter is required.") if query.empty?

        path_filter = (args["path"] || args[:path]).to_s.strip
        ext_filter = (args["extension"] || args[:extension]).to_s.strip

        path_filter, outside_error = BaseTool.normalize_path_filter(path_filter, @root_dir)
        if outside_error
          allowed = [{ path: @root_dir, primary: true }]
          idx = context_index
          idx.additional_roots.each { |r| allowed << { path: r, primary: false } } if idx.respond_to?(:additional_roots)
          return ToolOutput.error(DiagnosticReporter.render_traversal_blocked(args["path"] || args[:path], allowed_roots: allowed))
        end

        case_sensitive = args["case_sensitive"] || args[:case_sensitive] || false
        max_results = (args["max_results"] || args[:max_results] || 50).to_i
        max_results = 50 if max_results <= 0

        regex = regex_for(query, case_sensitive)

        matches = try_native_search(query, path_filter, ext_filter, case_sensitive, max_results, regex)
        matches ||= ruby_search(path_filter, ext_filter, regex, max_results)

        if matches.empty?
          "No matching lines found for '#{query}'.#{" (path filter: '#{path_filter}')" unless path_filter.empty?}"
        else
          lines = ["Found #{matches.size} match(es) for '#{query}':"]
          total_chars = 0
          capped = false
          matches.each do |m|
            content = sanitize_line_content(m[:content].to_s)
            entry = "#{m[:file]}:#{m[:line]}: #{content}"
            if (total_chars + entry.length) > MAX_OUTPUT_CHARS
              capped = true
              break
            end

            lines << entry
            total_chars += entry.length
          end
          lines << "... [Grep output capped at #{MAX_OUTPUT_CHARS / 1024}KB to protect context window. Narrow search via 'path' or 'extension']" if capped
          lines.join("\n")
        end
      rescue Errno::EACCES => e
        ToolOutput.error(DiagnosticReporter.render_permission_denied(path_filter.empty? ? @root_dir : path_filter, operation: "read", reason: e.message))
      rescue Rubik::Buffer::InvalidPathError
        ToolOutput.error(DiagnosticReporter.render_traversal_blocked(path_filter.empty? ? @root_dir : path_filter))
      end

      private

      # ripgrep fast path (Plan 52 D2/D7/D8). Gated so divergence risk stays
      # near zero: an unusable rg, a switched-off config, additional roots
      # rg cannot see, or a failed/untrusted run all return nil and the
      # pure-Ruby path renders the result instead. Dirty buffer entries are
      # re-scanned from memory so the model never sees stale disk content.
      def try_native_search(query, path_filter, ext_filter, case_sensitive, max_results, regex)
        return nil unless NativeSearch.enabled?(@config&.fetch("tools.native"))
        return nil unless NativeSearch.available?

        idx = context_index
        return nil if idx && !idx.additional_roots.empty?

        glob = nil
        unless ext_filter.empty?
          ext = ext_filter.start_with?(".") ? ext_filter[1..] : ext_filter
          glob = "*.#{ext}"
        end

        target = path_filter.empty? ? "." : path_filter.sub(%r{^\./}, "")

        native = NativeSearch.search(
          query,
          root_dir: @root_dir,
          path: target,
          glob: glob,
          case_sensitive: case_sensitive,
          max_results: max_results
        )
        return nil if native.nil?

        buf = buffer_manager
        dirty = buf&.dirty_files ? buf.dirty_files.keys : []
        native = native.reject { |m| dirty.include?(m[:file]) }
        scoped_dirty = dirty.select { |f| pass_path?(f, path_filter) && pass_extension?(f, ext_filter) }

        merge_native_results(native, scoped_dirty, regex, max_results)
      end

      # Memory-scans the dirty buffer files and merges them with the disk
      # (rg) results in the exact (file, line) order the pure-Ruby path has
      # always produced.
      def merge_native_results(native, scoped_dirty, regex, max_results)
        return native.sort_by { |m| [m[:file], m[:line]] } if scoped_dirty.empty?

        memory = collect_matches(scoped_dirty, regex, max_results, from_buffer: true)
        (native + memory).sort_by { |m| [m[:file], m[:line]] }.first(max_results)
      end

      # Pure-Ruby search over the context index (or a fresh scan). Reads
      # stay on the historical data path — buffer.read for every file when a
      # buffer manager exists (it warms the diff baseline), whole-content
      # strings otherwise — while the per-file line iteration avoids
      # materializing a line array.
      def ruby_search(path_filter, ext_filter, regex, max_results)
        idx = context_index
        files = if idx
                  idx.files.empty? ? idx.full_scan : idx.files
                else
                  Rubik::Context::Scanner.new(root_dir: @root_dir, native: @config&.fetch("tools.native")).scan
                end

        all_file_keys = files.keys
        all_file_keys = (all_file_keys + buffer_manager.dirty_files.keys).uniq if buffer_manager&.dirty_files
        all_file_keys = all_file_keys.select { |f| pass_path?(f, path_filter) }
        all_file_keys = all_file_keys.select { |f| pass_extension?(f, ext_filter) }

        collect_matches(all_file_keys.sort, regex, max_results, from_buffer: !buffer_manager.nil?)
      end

      # Iterates files in order, collecting matches until max_results.
      # from_buffer: content comes from buffer.read (memory or disk read into
      # a string — historical semantics, incl. the whole-content NUL check);
      # otherwise lines are streamed from disk with File.foreach. A NUL byte
      # in a streamed file revokes that file's earlier matches so the result
      # stays identical to the whole-content binary check.
      def collect_matches(file_keys, regex, max_results, from_buffer:)
        matches = []
        file_keys.each do |f|
          if from_buffer
            content = begin
              buffer_manager.read(f)
            rescue SystemCallError, IOError, Rubik::Buffer::InvalidPathError
              # InvalidPathError: an outbound symlink stays a per-file skip,
              # never an abort of the whole grep (the index lists symlinked
              # files on purpose).
              nil
            end
            next unless content.is_a?(String)
            next if content.include?("\x00")

            append_string_lines(matches, f, content, regex, max_results)
          else
            collect_disk_matches(matches, f, regex, max_results)
          end
          break if matches.size >= max_results
        end
        matches
      end

      def append_string_lines(matches, file_key, content, regex, max_results)
        line_no = 0
        content.each_line do |line_content|
          line_no += 1
          line_content = searchable_line(line_content)
          if regex.match?(line_content)
            matches << { file: file_key, line: line_no, content: sanitize_line_content(line_content.chomp) }
            break if matches.size >= max_results
          end
        end
      end

      # Buffer content and dirty-file edits may carry invalid UTF-8 (tool
      # output captured mid-stream, binary-ish edits). regex.match? raises
      # ArgumentError on such lines — scrub only the broken ones so the
      # common valid path pays only the cheap valid_encoding? check.
      def searchable_line(line)
        line.valid_encoding? ? line : line.scrub("")
      end

      def sanitize_line_content(content)
        return content if content.length <= MAX_LINE_CHARS

        "#{content[0..MAX_LINE_CHARS]}... [line truncated, #{content.length} chars total]"
      end

      def collect_disk_matches(matches, file_key, regex, max_results)
        full_p = File.expand_path(file_key, @root_dir)
        return unless File.exist?(full_p)

        line_no = 0
        # broken-encoding guard: a file saved in a non-UTF-8 codepage must not
        # raise out of regex matching; its valid bytes still get searched.
        File.foreach(full_p, encoding: "UTF-8") do |line_content|
          line_no += 1
          if line_content.include?("\x00")
            matches.delete_if { |m| m[:file] == file_key }
            break
          end
          line_content = searchable_line(line_content)
          next unless regex.match?(line_content)

          matches << { file: file_key, line: line_no, content: sanitize_line_content(line_content.chomp) }
          break if matches.size >= max_results
        end
      rescue SystemCallError, IOError, ArgumentError
        nil
      end

      def pass_path?(file_key, path_filter)
        return true if path_filter.empty?

        file_key.start_with?(path_filter.sub(%r{^\./}, ""))
      end

      def pass_extension?(file_key, ext_filter)
        return true if ext_filter.empty?

        ext = ext_filter.start_with?(".") ? ext_filter : ".#{ext_filter}"
        file_key.end_with?(ext)
      end

      def regex_for(query, case_sensitive)
        flags = case_sensitive ? nil : Regexp::IGNORECASE
        # Encoding hygiene: a query with invalid UTF-8 (model-transcription
        # artifact) raises RegexpError from Regexp.new and again from the
        # escape fallback. Scrub first so the fallback stays a true fallback,
        # and cover the escape branch with the same rescue.
        query = Rubik::Platform.safe_utf8(query)
        begin
          Regexp.new(query, flags)
        rescue RegexpError
          Regexp.new(Regexp.escape(query), flags)
        end
      end
    end
  end
end
