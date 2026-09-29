# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Plan 61 D-15: low-cost per-run ledger of tool usage, touched file
    # paths and tool errors, rendered into a compact turn summary. Failed
    # or cancelled turns persist this summary next to their [Turn ...]
    # marker so the model (and !resume) know what was already attempted.
    # Loop owns an instance and resets it per run; StepExecutor records.
    class ActivityLog
      def initialize
        @tools = Hash.new(0)
        @files = []
        @tool_errors = 0
        @entries = [] # YENİ (Plan 85 D-2): sıralı per-call kronoloji [{ tool:, status: }, ...]
      end

      def record(tool_name, tool_args, status)
        @tools[tool_name] += 1
        @entries << { tool: tool_name, status: status } # YENİ: sıra korunur
        path = tool_args["path"] || tool_args[:path]
        @files << path.to_s if path && @files.size < 10 && !@files.include?(path.to_s)
        @tool_errors += 1 if status == :error
      rescue StandardError => e
        Rubik::Platform.debug_warn("ActivityLog#record failed (#{e.class}: #{e.message}); telemetry entry dropped")
        nil
      end

      def summary(buffer_manager = nil)
        parts = []
        unless @tools.empty?
          used = @tools.map { |name, count| count > 1 ? "#{name}(x#{count})" : name }
          parts << "Tools used: #{used.join(', ')}"
        end
        parts << "Files touched: #{@files.join(', ')}" unless @files.empty?
        parts << "Tool errors encountered: #{@tool_errors}" if @tool_errors.positive?
        if buffer_manager&.dirty?
          dirty = buffer_manager.dirty_files
          names = dirty.is_a?(Hash) ? dirty.keys : Array(dirty)
          parts << "Unapplied buffer changes: #{names.join(', ')}" unless names.empty?
        end
        parts.join("\n")
      end

      # YENİ (Plan 85 D-2): Tüm tool çağrılarını gerçek kronolojik sırada döndürür.
      # Model context'ine enjekte için tasarlandı. @entries boşsa "" döner.
      def chronological_summary(max_entries: 20)
        return "" if @entries.empty?

        lines = @entries.first(max_entries).map.with_index(1) do |entry, i|
          status_tag = entry[:status] == :error ? " [FAILED]" : ""
          "  #{i}. #{entry[:tool]}#{status_tag}"
        end
        lines << "  ... (#{@entries.size - max_entries} more)" if @entries.size > max_entries
        lines.join("\n")
      end

      def reset!
        @tools.clear
        @files.clear
        @tool_errors = 0
        @entries.clear # YENİ
      end
    end
  end
end
