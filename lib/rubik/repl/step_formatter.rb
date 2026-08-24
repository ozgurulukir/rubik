# frozen_string_literal: true

require "json"

module Rubik
  module REPL
    class StepFormatter
      LEVEL_QUIET   = 0
      LEVEL_NORMAL  = 1
      LEVEL_VERBOSE = 2
      LEVEL_DEBUG   = 3

      attr_reader :level, :max_steps

      def self.normalize_level(val)
        case val.to_s.downcase.strip
        when "quiet", "0" then LEVEL_QUIET
        when "normal", "1" then LEVEL_NORMAL
        when "verbose", "2" then LEVEL_VERBOSE
        when "debug", "trace", "3" then LEVEL_DEBUG
        else LEVEL_NORMAL
        end
      end

      def initialize(config: nil, verbosity: nil, max_steps: nil)
        @config = config
        @max_steps = max_steps
        raw_verb = verbosity || config&.verbosity || "normal"
        @level = self.class.normalize_level(raw_verb)
      end

      def verbosity
        case @level
        when LEVEL_QUIET then "quiet"
        when LEVEL_NORMAL then "normal"
        when LEVEL_VERBOSE then "verbose"
        when LEVEL_DEBUG then "debug"
        else "normal"
        end
      end

      def format(step_info)
        return nil unless step_info.is_a?(Hash)

        type = step_info[:type]&.to_sym
        case type
        when :tool_call
          format_tool_call(step_info)
        when :tool_result
          format_tool_result(step_info)
        when :llm_thought
          format_llm_thought(step_info)
        when :step_warning
          format_step_warning(step_info)
        when :auto_apply
          format_auto_apply(step_info)
        when :emergency_compact
          format_emergency_compact(step_info)
        when :finish
          format_finish(step_info)
        when :message
          format_message(step_info)
        else
          nil
        end
      end

      def summarize_primary_arg(args)
        return "" unless args.is_a?(Hash) && !args.empty?

        primary_keys = %w[path file target_file filename command cmd query pattern message code url name role input]
        matched_key = primary_keys.find { |k| args.key?(k) || args.key?(k.to_sym) }

        if matched_key
          val = args.key?(matched_key) ? args[matched_key] : args[matched_key.to_sym]
          val_str = val.is_a?(String) ? "\"#{truncate_str(val, 50)}\"" : val.to_s
          "#{matched_key}: #{val_str}"
        else
          k, v = args.first
          v_str = v.is_a?(String) ? "\"#{truncate_str(v, 50)}\"" : v.to_s
          "#{k}: #{v_str}"
        end
      end

      def summarize_result(output, step_info = {})
        return step_info[:summary] if step_info[:summary] && !step_info[:summary].to_s.empty?

        lines = output.to_s.lines
        if lines.empty?
          "ok"
        elsif lines.size > 1
          "#{lines.size} lines"
        else
          line = lines.first.strip
          line.length > 60 ? "#{line[0..57]}..." : line
        end
      end

      private

      def truncate_str(str, max_len = 50)
        return str if str.length <= max_len

        "#{str[0...(max_len - 3)]}..."
      end

      def format_tool_call(step_info)
        return nil if @level == LEVEL_QUIET

        step = step_info[:step] || step_info[:current] || 1
        max = step_info[:max_steps] || step_info[:max] || @max_steps || "?"
        tool = step_info[:tool]
        args = step_info[:args] || {}
        call_id = step_info[:call_id]

        case @level
        when LEVEL_NORMAL
          summary = summarize_primary_arg(args)
          if summary.empty?
            " ▶ [Step #{step}/#{max}] #{tool}"
          else
            " ▶ [Step #{step}/#{max}] #{tool} (#{summary})"
          end
        when LEVEL_VERBOSE
          " ▶ [Step #{step}/#{max}] Calling #{tool} with args: #{JSON.generate(args)}"
        when LEVEL_DEBUG
          "[DEBUG:tool_call] step=#{step}/#{max} tool=#{tool} call_id=#{call_id} args=#{JSON.generate(args)}"
        end
      end

      def format_tool_result(step_info)
        return nil if @level == LEVEL_QUIET

        tool = step_info[:tool]
        status = (step_info[:status] || :ok).to_sym
        duration_ms = step_info[:duration_ms] || 0.0
        output = step_info[:output].to_s

        case @level
        when LEVEL_NORMAL
          if status == :ok
            summary_line = summarize_result(output, step_info)
            " ✔ [Obs] #{summary_line} (#{duration_ms}ms)"
          else
            err = step_info[:error]
            err = output.lines.first.to_s.strip if err.nil? || err.empty?
            err = "Command failed" if err.empty?
            " ✖ [Error] #{err} (#{duration_ms}ms)"
          end
        when LEVEL_VERBOSE
          lines_size = step_info[:line_count] || output.lines.size
          byte_size = step_info[:byte_size] || output.bytesize
          header = if status == :ok
                     " ✔ [Obs] #{lines_size} lines (#{byte_size} B, #{duration_ms}ms)"
                   else
                     err = step_info[:error]
                     err = output.lines.first.to_s.strip if err.nil? || err.empty?
                     err = "Command failed" if err.empty?
                     " ✖ [Error] #{err} (#{duration_ms}ms)"
                   end

          if !output.empty?
            preview = output.lines.first(5).map { |l| "     #{l.chomp}" }.join("\n")
            "#{header}\n   ↳ Preview:\n#{preview}"
          else
            header
          end
        when LEVEL_DEBUG
          "[DEBUG:tool_result] tool=#{tool} status=#{status} duration=#{duration_ms}ms\n#{output}"
        end
      end

      def format_llm_thought(step_info)
        return nil if @level == LEVEL_QUIET || @level == LEVEL_NORMAL

        content = step_info[:content].to_s.strip
        return nil if content.empty?

        clean_content = content.sub(/```(?:json)?\s*\{.*?\}\s*```/m, "").strip
        return nil if clean_content.empty?

        first_line = clean_content.lines.first.to_s.strip
        " 💭 [Thought] #{first_line}"
      end

      def format_step_warning(step_info)
        current = step_info[:current] || step_info[:step]
        max = step_info[:max] || step_info[:max_steps] || @max_steps
        remaining = step_info[:remaining] || ((max && current) ? (max.to_i - current.to_i) : 0)
        " ⚠️ [Rubik::Agent] Step budget warning: #{current}/#{max} steps used (#{remaining} remaining)."
      end

      def format_auto_apply(step_info)
        return nil if @level == LEVEL_QUIET

        files = step_info[:files] || []
        " ⚡ [Rubik::Buffer] Auto-applied #{files.size} modified file(s) to disk: #{files.join(', ')}"
      end

      def format_emergency_compact(_step_info)
        " ⚠️ [Rubik::Context] Context overflow auto-recovery: applied emergency compaction to history."
      end

      def format_finish(step_info)
        return nil if @level == LEVEL_QUIET

        message = (step_info[:message] || "Completed").to_s.strip
        " 🏁 [Rubik::Agent] Goal achieved: #{message}"
      end

      def format_message(step_info)
        return nil if @level == LEVEL_QUIET || @level == LEVEL_NORMAL || @level == LEVEL_VERBOSE

        content = step_info[:content]
        "[DEBUG:message] #{content}"
      end
    end
  end
end
