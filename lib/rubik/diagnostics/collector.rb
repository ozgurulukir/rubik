# frozen_string_literal: true

require_relative "entry"
require_relative "parser"

module Rubik
  module Diagnostics
    # Unified Diagnostic Fusion Engine (Plan 57 D-3).
    # Fuses LSP compiler diagnostics, static analysis / linter outputs, and test
    # runner error streams into a normalized, deduplicated, priority-ordered model.
    class Collector
      SEVERITY_ORDER = { error: 0, warning: 1, info: 2, hint: 3, unknown: 4 }.freeze
      LSP_SEVERITY_MAP = { 1 => :error, 2 => :warning, 3 => :info, 4 => :hint }.freeze

      attr_reader :root_dir, :lsp_manager

      def initialize(lsp_manager: nil, root_dir: Dir.pwd)
        @lsp_manager = lsp_manager
        @root_dir = File.expand_path(root_dir)
        @entries = []
        @mutex = Mutex.new
      end

      # Clears all collected diagnostics
      def clear!
        @mutex.synchronize { @entries.clear }
      end

      # Adds a normalized Entry object
      def add_entry(entry)
        return unless entry.is_a?(Entry)

        @mutex.synchronize { @entries << entry }
      end

      # Adds multiple Entry objects
      def add_entries(entries)
        return unless entries.is_a?(Array)

        @mutex.synchronize do
          entries.each { |e| @entries << e if e.is_a?(Entry) }
        end
      end

      # Parses CLI compiler/linter output and adds entries
      def add_parsed(output, lang: :unknown, source: :compiler)
        parsed = Parser.parse(output, lang)
        @mutex.synchronize do
          parsed.each do |e|
            rel_file = normalize_rel_path(e.file)
            @entries << Entry.new(
              file: rel_file,
              line: e.line,
              col: e.col,
              severity: e.severity || :error,
              code: e.code,
              message: e.message,
              category: e.category,
              raw_text: e.raw_text
            )
          end
        end
      end

      # Ingests raw LSP diagnostics from a file path
      def add_lsp_diagnostics(file_path, lsp_diags)
        return if lsp_diags.nil? || lsp_diags.empty?

        rel_file = normalize_rel_path(file_path)
        @mutex.synchronize do
          lsp_diags.each do |d|
            start_pos = d.dig("range", "start") || {}
            line = (start_pos["line"] || 0) + 1
            col = (start_pos["character"] || 0) + 1
            sev = LSP_SEVERITY_MAP[d["severity"]] || :error
            cat = d["severity"] == 1 ? :type : :lint

            @entries << Entry.new(
              file: rel_file,
              line: line,
              col: col,
              severity: sev,
              code: d["code"],
              message: d["message"].to_s.strip,
              category: cat,
              raw_text: d.to_s
            )
          end
        end
      end

      # Harvests live diagnostics from the LSP manager across all active servers
      def collect_lsp!(manager = @lsp_manager)
        return [] unless manager && manager.respond_to?(:all_diagnostics)

        all_diags = manager.all_diagnostics
        all_diags.each do |file_path, diags|
          add_lsp_diagnostics(file_path, diags)
        end
        entries
      end

      # Returns deduplicated, priority-sorted list of entries
      def entries(max_limit: 50)
        @mutex.synchronize do
          deduped = {}
          @entries.each do |e|
            key = [e.file, e.line, e.col, e.message]
            existing = deduped[key]
            deduped[key] = e if existing.nil? || SEVERITY_ORDER.fetch(e.severity, 4) < SEVERITY_ORDER.fetch(existing.severity, 4)
          end

          sorted = deduped.values.sort_by do |e|
            [
              SEVERITY_ORDER.fetch(e.severity, 4),
              e.file.to_s,
              e.line.to_i,
              e.col.to_i
            ]
          end

          sorted.first(max_limit)
        end
      end

      def errors
        entries.select { |e| e.severity == :error }
      end

      def warnings
        entries.select { |e| e.severity == :warning }
      end

      def empty?
        entries.empty?
      end

      def count
        entries.size
      end

      def error_count
        errors.size
      end

      def warning_count
        warnings.size
      end

      # Formats diagnostics as an XML block for LLM prompt context
      def format_for_context(max_limit: 30)
        current = entries(max_limit: max_limit)
        return "" if current.empty?

        lines = ["<diagnostics>"]
        current.each do |e|
          loc = e.file ? " file=\"#{e.file}\"" : ""
          loc += " line=\"#{e.line}\"" if e.line
          loc += " col=\"#{e.col}\"" if e.col
          lines << "  <issue severity=\"#{e.severity}\" category=\"#{e.category}\"#{loc}>#{escape_xml(e.message)}</issue>"
        end
        lines << "</diagnostics>"
        lines.join("\n")
      end

      # Formats diagnostics for terminal/REPL display
      def format_for_terminal
        current = entries
        return "No active compiler or linter diagnostics." if current.empty?

        lines = ["Diagnostic Fusion Summary (#{error_count} error(s), #{warning_count} warning(s)):"]
        current.each do |e|
          icon = e.severity == :error ? "❌ [ERROR]" : "⚠️ [WARN]"
          loc = e.file ? " #{e.file}:#{e.line || 1}" : ""
          loc += ":#{e.col}" if e.col
          lines << "  #{icon}#{loc} - #{e.message} (#{e.category})"
        end
        lines.join("\n")
      end

      private

      def escape_xml(str)
        str.to_s
           .gsub("&", "&amp;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub('"', "&quot;")
      end

      def normalize_rel_path(path)
        return nil if path.nil? || path.to_s.empty?

        norm_path = path.to_s.tr("\\", "/")
        norm_root = @root_dir.to_s.tr("\\", "/")
        norm_path.sub(%r{^#{Regexp.escape(norm_root)}/}, "")
      end
    end
  end
end
