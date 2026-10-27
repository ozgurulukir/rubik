# frozen_string_literal: true

require "json"
require_relative "../platform"
require_relative "../uris"
require_relative "../repl/step_formatter"
require_relative "spinner"
require_relative "capability"
require_relative "theme"

module Rubik
  module UI
    # Display formatter for orchestrator step events implementing the Rubik
    # agent-flow visual language:
    #
    #   ✻ Kavuruyor · 3s (ctrl+c: kes)          <- live spinner (UI::Spinner)
    #   ⏺ read_file — lib/main.rb               <- action line
    #     ⎿ 3 lines · 15.2ms                    <- nested result branch
    #
    # Responsibilities (Plan 51, Decision D2 — StepFormatter stays the
    # semantic layer, this class is the presentation decorator):
    #   * owns the Spinner lifecycle (:thinking starts it, any other event
    #     stops it before text is printed),
    #   * maps the 13 orchestrator event types to the glyph tree at
    #     normal/verbose levels, consuming the legacy formatter's public
    #     semantic helpers (thinking_parts, primary_arg_value,
    #     summarize_result, thought_first_line) instead of re-parsing events,
    #   * delegates raw [DEBUG:...] lines verbatim at debug level and
    #     re-anchors stable event bodies (warnings, retries, finish) with
    #     two leading spaces,
    #   * paints through the Theme so disabled color yields plain text with
    #     identical glyphs (one visual language, deterministic pipes).
    class Renderer
      LEVEL_QUIET = Rubik::REPL::StepFormatter::LEVEL_QUIET

      attr_reader :spinner, :theme

      def initialize(output:, config: nil, verbosity: nil, max_steps: nil, theme: nil)
        @config = config
        @max_steps = max_steps
        @output = output
        @theme = theme || Theme.for(output, config)
        @legacy = Rubik::REPL::StepFormatter.new(config: config, verbosity: verbosity, max_steps: max_steps)
        @spinner = Spinner.new(output, @theme, config: config)
        @spinner_capable = Capability.spinner?(output, config) && level > LEVEL_QUIET
      end

      def level
        @legacy.level
      end

      # Renders one orchestrator event to a printable String (or nil to stay
      # silent). Must be called for EVERY event so the spinner is stopped
      # before any other output is printed.
      def render(step_info)
        return nil unless step_info.is_a?(Hash)

        type = step_info[:type]&.to_sym

        # Teslimat süslemeden önce gelir: :user_output debug dahil her
        # seviyede doğrudan işlenir — debug delegasyonu onu StepFormatter'a
        # (kolu yok → nil) götürür ve stub yalan olurdu.
        return render_user_output(step_info) if type == :user_output

        # Raw debug lines come verbatim from the legacy formatter.
        return @legacy.format(step_info) if level >= Rubik::REPL::StepFormatter::LEVEL_DEBUG

        case type
        when :thinking then render_thinking(step_info)
        when :tool_call then render_tool_call(step_info)
        when :tool_result then render_tool_result(step_info)
        when :user_output then render_user_output(step_info)
        when :llm_thought then render_llm_thought(step_info)
        when :chunk, :chunk_end
          @spinner.stop
          nil
        else
          restyle_legacy(step_info)
        end
      end

      private

      def render_thinking(step_info)
        return nil if level <= LEVEL_QUIET

        if @spinner_capable
          @spinner.start(step: step_info[:step], max_steps: step_info[:max_steps])
          return nil
        end

        parts = @legacy.thinking_parts(step_info)
        target_part = parts[:target].empty? ? "" : " (#{parts[:target]})"
        "#{@theme.glyph(:clock)} #{@theme.spinner_verbs.first} [#{parts[:step]}/#{parts[:max]}]#{target_part}"
      end

      def render_tool_call(step_info)
        @spinner.stop
        return nil if level <= LEVEL_QUIET

        tool = step_info[:tool]
        args = step_info[:args] || {}
        header = @theme.paint("#{@theme.glyph(:action)} #{tool}", :accent)

        if level >= Rubik::REPL::StepFormatter::LEVEL_VERBOSE
          "#{header} #{@theme.paint(Rubik::Platform.safe_json_generate(args), :dim)}"
        else
          summary = pretty_storage_arg(@legacy.primary_arg_value(args).to_s)
          summary.empty? ? header : "#{header} #{theme_dim_dash(summary)}"
        end
      end

      # Depo varlıklarını kullanıcıya 'göster' dendiğinde ajan uzun
      # rubik://storage URI'leri kullanır; eylem satırında önek düşer,
      # içerik karması 8 hexe kısaltılır (storage-show-surface planı C).
      #   rubik://storage/js-tangram/review/review.1.b54cddc277e87d25
      #   → js-tangram/review/review.1.b54cddc2…
      def pretty_storage_arg(value)
        rel = Rubik::Uris.storage_relative(value)
        return value unless rel

        rel.sub(/\.json\z/i, "").sub(/([0-9a-f]{8})[0-9a-f]{8}\z/i, "\\1…")
      end

      # :user_output (show_file sözleşmesi): tam içerik kullanıcıya aynen
      # akar — soluklaştırılmaz, okunabilirlik önce gelir; yalnız başlık
      # satırı dim boyanır. Model bu içeriği görmedi (stub aldı). Bu event
      # süsleme değil TESLİMAT'tır: quiet dahil her seviyede basılır
      # (sessiz düşüş, modelin "rendered to terminal" stub'ını yalan yapar).
      def render_user_output(step_info)
        @spinner.stop

        header = @theme.paint("#{@theme.glyph(:branch)} #{step_info[:label]}", :dim)
        "#{header}\n#{step_info[:content]}\n"
      end

      def render_tool_result(step_info)
        @spinner.stop
        return nil if level <= LEVEL_QUIET

        status = (step_info[:status] || :ok).to_sym
        duration = step_info[:duration_ms] || 0.0
        output = step_info[:output].to_s
        branch = "#{@theme.glyph(:branch)} "

        if status != :ok
          err = step_info[:error]
          err = output.lines.first.to_s.strip if err.nil? || err.to_s.empty?
          err = "Command failed" if err.to_s.empty?
          if err.start_with?("Security blocked:") || output.start_with?("Security blocked:")
            sec_line = output.lines.first.to_s.strip
            hint = output[/!(?:allow-cmd|allow-dir)\s+[^\n]+/]&.strip
            msg = hint ? "#{sec_line} [#{hint}]" : sec_line
            "#{branch}#{@theme.paint("#{@theme.glyph(:warn)} #{msg}", :warn)}"
          else
            "#{branch}#{@theme.paint("#{@theme.glyph(:err)} #{err} (#{duration}ms)", :error)}"
          end
        elsif level >= Rubik::REPL::StepFormatter::LEVEL_VERBOSE
          lines_size = step_info[:line_count] || output.lines.size
          byte_size = step_info[:byte_size] || output.bytesize
          header = "#{branch}#{lines_size} lines (#{byte_size} B, #{duration}ms)"
          return @theme.paint(header, :dim) if output.empty?

          preview = output.lines.first(5).map { |l| "    #{l.chomp}" }.join("\n")
          "#{@theme.paint(header, :dim)}\n#{@theme.paint("    #{@theme.glyph(:preview)} Preview:", :dim)}\n#{@theme.paint(preview, :dim)}"
        else
          summary = @legacy.summarize_result(output, step_info)
          "#{branch}#{@theme.paint("#{summary} · #{duration}ms", :dim)}"
        end
      end

      def render_llm_thought(step_info)
        @spinner.stop
        return nil if level < Rubik::REPL::StepFormatter::LEVEL_VERBOSE
        return nil if step_info[:streamed] == true

        first_line = @legacy.thought_first_line(step_info[:content])
        return nil if first_line.nil? || first_line.empty?

        "  #{@theme.paint("#{@theme.glyph(:thought)} #{first_line}", :thought)}"
      end

      # Events whose message bodies stay stable (warnings, retries, finish,
      # auto-apply, compaction): keep the legacy text, re-anchor it to the
      # glyph tree with two leading spaces.
      def restyle_legacy(step_info)
        @spinner.stop
        legacy_line = @legacy.format(step_info)
        return nil if legacy_line.nil? || legacy_line.empty?

        styled = case step_info[:type]&.to_sym
                 when :step_warning, :emergency_compact, :llm_retry
                   @theme.paint(legacy_line.strip, :warn)
                 when :auto_apply, :finish
                   @theme.paint(legacy_line.strip, :success)
                 else
                   legacy_line.strip
                 end
        "  #{styled}"
      end

      def theme_dim_dash(text)
        @theme.paint("— #{text}", :dim)
      end
    end
  end
end
