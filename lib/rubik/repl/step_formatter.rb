# frozen_string_literal: true

require "json"
require_relative "../platform"

module Rubik
  module REPL
    class StepFormatter
      LEVEL_QUIET   = 0
      LEVEL_NORMAL  = 1
      LEVEL_VERBOSE = 2
      LEVEL_DEBUG   = 3

      # Canonical argument keys considered the "primary" operand of a tool
      # call, shared with UI::Renderer (Plan 51, Decision D2).
      PRIMARY_ARG_KEYS = ["path", "file", "target_file", "filename", "command", "cmd", "query", "pattern", "message", "code", "url", "name", "role",
                          "input"].freeze

      attr_reader :level, :max_steps

      def self.normalize_level(val)
        case val.to_s.downcase.strip
        when "quiet", "0" then LEVEL_QUIET
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
        when LEVEL_VERBOSE then "verbose"
        when LEVEL_DEBUG then "debug"
        else "normal"
        end
      end

      def format(step_info)
        return nil unless step_info.is_a?(Hash)

        type = step_info[:type]&.to_sym
        case type
        when :thinking
          format_thinking(step_info)
        when :tool_call
          format_tool_call(step_info)
        when :tool_result
          format_tool_result(step_info)
        when :llm_thought
          format_llm_thought(step_info)
        when :step_warning
          format_step_warning(step_info)
        when :llm_retry
          format_llm_retry(step_info)
        when :auto_apply
          format_auto_apply(step_info)
        when :emergency_compact
          format_emergency_compact(step_info)
        when :finish
          format_finish(step_info)
        when :message
          format_message(step_info)
        when :chunk, :chunk_end
          nil
        end
      end

      def format_thinking(step_info)
        return nil if @level == LEVEL_QUIET

        parts = thinking_parts(step_info)
        target_str = parts[:target].empty? ? "" : " (#{parts[:target]})"

        case @level
        when LEVEL_NORMAL
          " ⏳ [Step #{parts[:step]}/#{parts[:max]}] Thinking...#{target_str}"
        when LEVEL_VERBOSE
          " ⏳ [Step #{parts[:step]}/#{parts[:max]}] Querying LLM#{target_str}..."
        when LEVEL_DEBUG
          "[DEBUG:thinking] step=#{parts[:step]}/#{parts[:max]} provider=#{step_info[:provider]} model=#{step_info[:model]}"
        end
      end

      # Semantic decomposition shared with UI::Renderer: step budget parts
      # and the "provider/model" target label of a :thinking event.
      def thinking_parts(step_info)
        step = step_info[:step] || step_info[:current] || 1
        max = step_info[:max_steps] || step_info[:max] || @max_steps || "?"
        target = [step_info[:provider], step_info[:model]].compact.reject { |s| s.to_s.strip.empty? }.join("/")
        { step: step, max: max, target: target }
      end

      def summarize_primary_arg(args)
        return "" unless args.is_a?(Hash) && !args.empty?

        matched_key = PRIMARY_ARG_KEYS.find { |k| args.key?(k) || args.key?(k.to_sym) }

        if matched_key
          "#{matched_key}: #{format_arg_value(primary_arg_value(args))}"
        else
          k, v = args.first
          "#{k}: #{format_arg_value(v)}"
        end
      end

      # Raw value of the primary operand (no key prefix, no quoting) — the
      # semantic twin of #summarize_primary_arg consumed by UI::Renderer.
      def primary_arg_value(args)
        return "" unless args.is_a?(Hash) && !args.empty?

        matched_key = PRIMARY_ARG_KEYS.find { |k| args.key?(k) || args.key?(k.to_sym) }
        key = matched_key || args.first[0]
        args.key?(key) ? args[key] : args[key.to_sym]
      end

      def format_arg_value(val)
        val.is_a?(String) ? "\"#{truncate_str(val, 50)}\"" : val.to_s
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

      # First printable line of an assistant thought with fenced JSON tool
      # blocks stripped; nil when nothing human-readable remains. Shared
      # with UI::Renderer (Plan 51, Decision D2).
      def thought_first_line(content)
        clean_content = content.to_s.sub(/```(?:json)?\s*\{.*?\}\s*```/m, "").strip
        return nil if clean_content.empty?

        clean_content.lines.first.to_s.strip
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
          " ▶ [Step #{step}/#{max}] Calling #{tool} with args: #{Rubik::Platform.safe_json_generate(args)}"
        when LEVEL_DEBUG
          "[DEBUG:tool_call] step=#{step}/#{max} tool=#{tool} call_id=#{call_id} args=#{Rubik::Platform.safe_json_generate(args)}"
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

          if output.empty?
            header
          else
            preview = output.lines.first(5).map { |l| "     #{l.chomp}" }.join("\n")
            "#{header}\n   ↳ Preview:\n#{preview}"
          end
        when LEVEL_DEBUG
          "[DEBUG:tool_result] tool=#{tool} status=#{status} duration=#{duration_ms}ms\n#{output}"
        end
      end

      # First printable line of an assistant thought with fenced JSON tool
      # blocks stripped; nil when nothing human-readable remains. Shared
      # with UI::Renderer (Plan 51, Decision D2).
      def format_llm_thought(step_info)
        return nil if @level == LEVEL_QUIET || @level == LEVEL_NORMAL

        first_line = thought_first_line(step_info[:content])
        return nil if first_line.nil? || first_line.empty?

        " 💭 [Thought] #{first_line}"
      end

      def format_step_warning(step_info)
        current = step_info[:current] || step_info[:step]
        max = step_info[:max] || step_info[:max_steps] || @max_steps
        remaining = step_info[:remaining] || (max && current ? (max.to_i - current.to_i) : 0)
        " ⚠️ [Rubik::Agent] Step budget warning: #{current}/#{max} steps used (#{remaining} remaining)."
      end

      def format_llm_retry(step_info)
        return nil if @level == LEVEL_QUIET

        attempt = step_info[:attempt] || "?"
        max = step_info[:max] || "?"
        reason = step_info[:reason].to_s
        if @level == LEVEL_DEBUG
          "[DEBUG:llm_retry] step=#{step_info[:step] || '?'}/#{step_info[:max_steps] || '?'} retry=#{attempt}/#{max} reason=#{reason}"
        else
          " ↻ [Rubik::LLM] retry #{attempt}/#{max} (#{reason})"
        end
      end

      def format_auto_apply(step_info)
        return nil if @level == LEVEL_QUIET

        files = step_info[:files] || []
        " ⚡ [Rubik::Buffer] Auto-applied #{files.size} modified file(s) to disk: #{files.join(', ')}"
      end

      def format_emergency_compact(_step_info)
        " ⚠️ [Rubik::Context] Context overflow auto-recovery: applied emergency compaction to history."
      end

      # The full answer is rendered exactly once elsewhere (live chunks or
      # the post-loop markdown render); this header stays to ONE line so the
      # whole text is never printed twice. The suffix must tell the truth
      # about WHERE the content went: streamed turns show "(+N more lines)"
      # — the text is already above; batch turns say "(full answer below)"
      # because the post-loop render follows immediately. A missing :streamed
      # key defaults to streamed (the dominant interactive path).
      def format_finish(step_info)
        return nil if @level == LEVEL_QUIET

        message = (step_info[:message] || "Completed").to_s.strip
        return " 🏁 [Rubik::Agent] Completed" if message.empty?

        streamed = step_info.key?(:streamed) ? step_info[:streamed] == true : true
        return " 🏁 [Rubik::Agent] Completed (full answer below)" unless streamed

        lines = message.lines
        first = lines.first.to_s.strip
        suffix = lines.count > 1 ? " (+#{lines.count - 1} more lines)" : ""
        " 🏁 [Rubik::Agent] Completed: #{first}#{suffix}"
      end

      def format_message(step_info)
        return nil if @level == LEVEL_QUIET || @level == LEVEL_NORMAL || @level == LEVEL_VERBOSE

        content = step_info[:content]
        "[DEBUG:message] #{content}"
      end
    end
  end
end
