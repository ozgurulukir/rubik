# frozen_string_literal: true

module Rubik
  module Tools
    # Generates empathetic, actionable Elm-compiler-style error diagnostics (Plan 56 D-2).
    # Combines clear problem statements, context inspection, "Did you mean?" suggestions,
    # and numbered next steps to optimize LLM self-healing on first attempt.
    class DiagnosticReporter
      HEADER_WIDTH = 70

      def self.box_header(title)
        dashes_len = [HEADER_WIDTH - title.length - 4, 4].max
        "-- #{title.upcase} #{"-" * dashes_len}"
      end

      # Elm-style diagnostic when a file path does not exist in workspace.
      def self.render_file_not_found(path, candidates: [], existing_dir_files: [])
        lines = [box_header("File Not Found")]
        lines << "I cannot find the file `#{path}` in the project workspace."
        lines << ""

        if candidates && !candidates.empty?
          lines << "Did you mean this?"
          candidates.each { |c| lines << "    • #{c}" }
          lines << ""
        end

        if existing_dir_files && !existing_dir_files.empty?
          dir_name = File.dirname(path)
          display_dir = dir_name == "." ? "project root" : "`#{dir_name}/`"
          lines << "Existing files in #{display_dir}:"
          existing_dir_files.first(8).each { |f| lines << "    • #{f}" }
          lines << ""
        end

        lines << "Actionable Next Steps:"
        if candidates && !candidates.empty?
          lines << "  1. If you meant an existing file, call `read_file(path: '#{candidates.first}')`."
        else
          lines << "  1. Verify the exact path or explore directory structure using `list_files(path: '#{File.dirname(path)}')`."
        end
        lines << "  2. If you want to create this new file, call `write_file(path: '#{path}', content: '...')`."
        lines << "  3. To search for code containing this filename, call `grep_search(query: '#{File.basename(path)}')`."

        lines.join("\n")
      end

      # Elm-style diagnostic when target_content is not found in the file or range.
      def self.render_target_not_found(path, target_content, closest_snippet: nil, closest_range: nil, similarity: nil, start_line: nil, end_line: nil)
        range_str = (start_line || end_line) ? " within lines #{start_line || 1}..#{end_line || 'end'}" : ""
        lines = [box_header("Target Content Not Found")]
        lines << "I could not find the exact `target_content` in `#{path}`#{range_str}."
        lines << ""
        lines << "Target content requested:"
        lines << format_snippet_box(target_content)
        lines << ""

        if closest_snippet && !closest_snippet.empty?
          sim_str = similarity ? " (#{similarity}% similarity)" : ""
          range_label = closest_range ? "lines #{closest_range.begin}..#{closest_range.end}" : "nearby lines"
          lines << "Closest matching snippet found at #{range_label}#{sim_str}:"
          lines << format_snippet_box(closest_snippet)
          lines << ""
        end

        suggested_offset = closest_range ? [closest_range.begin - 2, 1].max : [start_line.to_i - 5, 1].max
        lines << "Actionable Next Steps:"
        lines << "  1. Call `read_file(path: '#{path}', offset: #{suggested_offset}, limit: 25)` to inspect exact indentation, whitespace, and line content."
        lines << "  2. Re-run `replace_file_content` with the exact verbatim lines from the file."
        if start_line || end_line
          lines << "  3. Or omit `start_line`/`end_line` if the target content moved elsewhere in the file."
        end

        lines.join("\n")
      end

      # Elm-style diagnostic when target_content matches multiple locations.
      def self.render_target_not_unique(path, target_content, match_count, line_occurrences = [])
        lines = [box_header("Target Content Not Unique")]
        occ_str = line_occurrences.empty? ? "" : " at lines: #{line_occurrences.join(', ')}"
        lines << "The specified `target_content` was found #{match_count} times in `#{path}`#{occ_str}."
        lines << ""
        lines << "Target content:"
        lines << format_snippet_box(target_content)
        lines << ""
        lines << "Actionable Next Steps:"
        lines << "  1. Provide more surrounding context lines in `target_content` to make the match unique."
        if line_occurrences && line_occurrences.size >= 2
          first_occ = line_occurrences.first
          lines << "  2. Or restrict the search range with `start_line` and `end_line` (e.g. `start_line: #{[first_occ - 2, 1].max}, end_line: #{first_occ + target_content.to_s.lines.size + 2}`)."
        else
          lines << "  2. Or specify `start_line` and `end_line` to target the exact occurrence."
        end
        lines << "  3. If you intentionally want to replace ALL #{match_count} occurrences across the entire file, pass `allow_multiple: true`."

        lines.join("\n")
      end

      # Elm-style diagnostic when a tool name is unrecognized.
      def self.render_unknown_tool(tool_name, candidate_tools: [], all_tools: [])
        lines = [box_header("Unknown Tool")]
        lines << "I cannot find an active tool named `#{tool_name}`."
        lines << ""

        if candidate_tools && !candidate_tools.empty?
          lines << "Did you mean one of these?"
          candidate_tools.each { |c| lines << "    • #{c}" }
          lines << ""
        end

        if all_tools && !all_tools.empty?
          formatted_tools = all_tools.map { |t| "`#{t}`" }.join(", ")
          lines << "Available direct tools in toolbelt:"
          lines << "    #{formatted_tools}"
          lines << ""
        end

        lines << "💡 Need a specialized capability?"
        lines << "    You can dynamically create and register your own custom tool at runtime using:"
        lines << "    `synthesize_tool(name: '#{tool_name.to_s.downcase}', description: '...', code: '->(args) { ... }')`"

        lines.join("\n")
      end

      # Elm-style diagnostic when a symbol definition is not found in AST.
      def self.render_symbol_not_found(sym_name, candidate_symbols: [])
        lines = [box_header("Symbol Not Found")]
        lines << "I could not find the symbol `#{sym_name}` in the AST semantic graph."
        lines << ""

        if candidate_symbols && !candidate_symbols.empty?
          lines << "Did you mean one of these?"
          candidate_symbols.each { |s| lines << "    • #{s}" }
          lines << ""
        end

        lines << "Actionable Next Steps:"
        lines << "  1. Search for partial matches using `search_symbols(query: '#{sym_name.to_s[0..4]}')`."
        lines << "  2. Search for code occurrences across the workspace with `grep_search(query: '#{sym_name}')`."
        lines << "  3. Inspect a specific file outline with `get_outline(file_path: '...')`."

        lines.join("\n")
      end

      # Elm-style diagnostic when a shell/sandbox command fails.
      def self.render_command_failed(cmd, exit_code, stderr, suggestions: [])
        lines = [box_header("Command Execution Failed")]
        lines << "Command `#{cmd}` failed with exit code #{exit_code}."
        lines << ""
        if stderr && !stderr.to_s.strip.empty?
          lines << "Output / Error:"
          lines << format_snippet_box(stderr.to_s.strip)
          lines << ""
        end

        if suggestions && !suggestions.empty?
          lines << "Actionable Next Steps:"
          suggestions.each_with_index { |s, idx| lines << "  #{idx + 1}. #{s}" }
        end

        lines.join("\n")
      end

      # Elm-style diagnostic when operating system permissions prevent file/directory access (Errno::EACCES).
      def self.render_permission_denied(path, operation: "read", reason: nil)
        lines = [box_header("Permission Denied")]
        reason_str = reason ? " (#{reason})" : " (Errno::EACCES)"
        op_text = operation.to_s == "read" ? "access" : operation.to_s
        lines << "I cannot #{op_text} `#{path}` due to operating system permission restrictions#{reason_str}."
        lines << ""
        lines << "Actionable Next Steps:"
        lines << "  1. If this is a scratch or temporary directory, allow it via REPL: `!allow #{path}`"
        lines << "  2. Ensure the process has proper OS #{operation} permissions for this directory."
        lines << "  3. Target a specific accessible subfolder using `list_files(path: 'accessible_dir')`."

        lines.join("\n")
      end

      # Elm-style diagnostic when path traversal is blocked outside allowed workspace roots.
      def self.render_traversal_blocked(path, allowed_roots: [], allowed_exts: [])
        lines = [box_header("Path Access Restricted (Sandbox Gate)")]
        lines << "Access to `#{path}` was blocked because it is outside the project workspace."
        lines << ""

        roots = Array(allowed_roots)
        if !roots.empty?
          lines << "Configured Allowed Roots:"
          roots.each do |root_info|
            if root_info.is_a?(Hash)
              tag = root_info[:primary] ? "[PRIMARY]" : "[ALLOWED]"
              note = root_info[:zero_ast] ? " (Zero-AST)" : ""
              lines << "    • #{tag} #{root_info[:path]}#{note}"
            else
              lines << "    • #{root_info}"
            end
          end
          lines << ""
        end

        lines << "Actionable Next Steps:"
        lines << "  1. Use a path relative to the project root (e.g. 'lib', 'src') or explore with `list_files`."
        lines << "  2. To allow transient I/O and sandbox access to this folder without AST bloat, run:"
        lines << "     `!allow #{path}`"
        lines << "  3. To add it as a full workspace root with AST indexing, run:"
        lines << "     `!workspace add #{path} [--rw]`"

        lines.join("\n")
      end

      # Elm-style diagnostic when malformed or invalid UTF-8 byte sequences are detected.
      def self.render_encoding_warning(source, sample_snippet: nil)
        lines = [box_header("Encoding Warning (Malformed UTF-8)")]
        lines << "Malformed or invalid UTF-8 byte sequences detected in `#{source}`."
        lines << "The input has been automatically sanitized with lossless replacement characters."
        lines << ""

        if sample_snippet && !sample_snippet.to_s.empty?
          lines << "Sanitized Sample Preview:"
          lines << format_snippet_box(sample_snippet)
          lines << ""
        end

        lines << "Actionable Next Steps:"
        lines << "  1. Ensure source files and command inputs are encoded in standard UTF-8."
        lines << "  2. For binary or non-text files, use dedicated binary inspection or base64 decoding."

        lines.join("\n")
      end

      # Elm-style diagnostic guidance for LLM context window utilization and token management.
      def self.render_context_status_guidance(stats, token_breakdown: {})
        lines = [box_header("Context Window & Token Guidance")]
        stats_hash = stats.is_a?(Hash) ? stats : {}
        model_name = stats_hash[:model] || stats_hash["model"] || "active model"
        used_tokens = stats_hash[:consumed_tokens] || stats_hash[:estimated_tokens] || stats_hash["consumed_tokens"] || 0
        limit_tokens = stats_hash[:context_limit] || stats_hash[:usable_capacity] || stats_hash["context_limit"] || 32_768
        pct = limit_tokens.positive? ? ((used_tokens.to_f / limit_tokens) * 100).round(1) : 0.0

        lines << "Current Context Utilization: #{used_tokens} / #{limit_tokens} tokens (#{pct}%) for `#{model_name}`"
        lines << ""

        breakdown_hash = token_breakdown.is_a?(Hash) ? token_breakdown : {}
        if !breakdown_hash.empty?
          lines << "Token Breakdown:"
          breakdown_hash.each do |k, v|
            lines << "    • #{k}: #{v} tokens"
          end
          lines << ""
        end

        lines << "Actionable Next Steps:"
        if pct >= 80.0
          lines << "  1. Context window is nearly full (>=80%). Run `!context compact` to prune older conversation turns."
          lines << "  2. Switch to a higher-capacity model using `!model default <provider>/<model>`."
          lines << "  3. Drop unnecessary indexed files using `!context drop <path>`."
        elsif pct >= 50.0
          lines << "  1. Context utilization is moderate (>=50%). Use `!context stats` to monitor token growth."
          lines << "  2. Consider running `!context compact` before lengthy multi-step goal loops."
        else
          lines << "  1. Context window is healthy with ample headroom (<50%)."
          lines << "  2. Continue normal interactions or add context with `!context add <path>`."
        end

        lines.join("\n")
      end

      def self.format_snippet_box(text)
        text.to_s.lines.map { |l| "    #{l.chomp}" }.join("\n")
      end
    end
  end
end
