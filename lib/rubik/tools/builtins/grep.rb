# frozen_string_literal: true

require_relative "../base"
require_relative "../native_search"
require_relative "../diagnostic_reporter"

module Rubik
  module Tools
    class GrepSearchTool < BaseTool
      def initialize(buffer_manager = nil, context_index = nil, root_dir: Dir.pwd, runtime_context: nil, context: nil, config: nil)
        super(
          name: "grep_search",
          aliases: ["search_code", "grep", "search_files"],
          description: "Search for exact string or regular expression across project files with line numbers and matched content",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              query: { type: "string", description: "Text or regex pattern to search for" },
              path: { type: "string",
                      description: "Subdirectory or file path relative to the project root (e.g. 'lib', 'src/main.go'). Absolute paths are converted automatically. (optional)" },
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
        @config = config
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

        path_filter, outside_error = BaseTool.normalize_path_filter(path_filter, @root_dir)
        if outside_error
          allowed = [{ path: @root_dir, primary: true }]
          idx = context_index
          idx.additional_roots.each { |r| allowed << { path: r, primary: false } } if idx.respond_to?(:additional_roots)
          return DiagnosticReporter.render_traversal_blocked(args["path"] || args[:path], allowed_roots: allowed)
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
          matches.each do |m|
            lines << "#{m[:file]}:#{m[:line]}: #{m[:content]}"
          end
          lines.join("\n")
        end
      rescue Errno::EACCES => e
        DiagnosticReporter.render_permission_denied(path_filter.empty? ? @root_dir : path_filter, operation: "read", reason: e.message)
      rescue Rubik::Buffer::InvalidPathError, StandardError => e
        if e.class.name.include?("InvalidPathError")
          return DiagnosticReporter.render_traversal_blocked(path_filter.empty? ? @root_dir : path_filter)
        end

        raise
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
            rescue StandardError
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
          if regex.match?(line_content)
            matches << { file: file_key, line: line_no, content: line_content.chomp }
            break if matches.size >= max_results
          end
        end
      end

      def collect_disk_matches(matches, file_key, regex, max_results)
        full_p = File.expand_path(file_key, @root_dir)
        return unless File.exist?(full_p)

        line_no = 0
        File.foreach(full_p) do |line_content|
          line_no += 1
          if line_content.include?("\x00")
            matches.delete_if { |m| m[:file] == file_key }
            return
          end
          next unless regex.match?(line_content)

          matches << { file: file_key, line: line_no, content: line_content.chomp }
          break if matches.size >= max_results
        end
      rescue StandardError
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
        begin
          Regexp.new(query, flags)
        rescue RegexpError
          Regexp.new(Regexp.escape(query), flags)
        end
      end
    end
  end
end
