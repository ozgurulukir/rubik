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
      end

      def record(tool_name, tool_args, status)
        @tools[tool_name] += 1
        path = tool_args["path"] || tool_args[:path]
        if path && @files.size < 10 && !@files.include?(path.to_s)
          @files << path.to_s
        end
        @tool_errors += 1 if status == :error
      rescue StandardError
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

      def reset!
        @tools.clear
        @files.clear
        @tool_errors = 0
      end
    end
  end
end
