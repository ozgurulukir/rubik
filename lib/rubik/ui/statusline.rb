# frozen_string_literal: true

require_relative "../prompt/token_estimator"

module Rubik
  module UI
    # Compact context strip printed above the prompt line before every read:
    # active model, estimated context-window usage, dirty buffer count and
    # sandbox state. Customizable via `ui.statusline_template` placeholders:
    #   {project} {branch} {model} {ctx} {dirty} {sandbox} {verbosity}
    module Statusline
      module_function

      def render(shell, theme)
        return nil unless shell.config.fetch("ui.statusline", true)

        template = shell.config.fetch("ui.statusline_template", default_template)
        # `!config set ui.statusline_template "{a} {b}"` can arrive parsed as
        # a YAML flow-mapping Hash; coerce any non-String back to the default.
        template = default_template unless template.is_a?(String)

        routed = current_route(shell)
        values = {
          "project" => File.basename(shell.buffer_manager&.root_dir || Dir.pwd),
          "branch" => shell.detect_git_branch || "-",
          "model" => model_label(routed),
          "ctx" => context_usage(shell, routed),
          "dirty" => dirty_segment(shell, theme),
          "sandbox" => sandbox_segment(shell),
          "verbosity" => shell.config.fetch("ui.verbosity", "normal")
        }

        line = template.gsub(/\{(\w+)\}/) { values.fetch(::Regexp.last_match(1)) { "{#{::Regexp.last_match(1)}}" } }
        theme.paint(line, :dim)
      end

      def default_template
        "{model} · ctx {ctx} · {dirty} · sandbox {sandbox}"
      end

      def current_route(shell)
        shell.router.route(task_type: :default)
      rescue StandardError
        nil
      end

      # "provider/model" label shared with the banner.
      def model_label(routed)
        return "-" unless routed

        "#{routed[:spec]['provider']}/#{routed[:model]}"
      end

      # Estimated share of the context window consumed by the in-memory
      # dialogue history, e.g. "34%" (or "-" when the limit is unknown).
      def context_usage(shell, routed)
        limit = routed&.fetch(:context_limit, nil).to_i
        return "-" unless limit.positive?

        tokens = Rubik::Prompt::TokenEstimator.estimate_history(shell.conversation_history)
        pct = ((tokens.to_f / limit) * 100).round
        pct = 100 if pct > 100
        "#{pct}%"
      end

      def dirty_segment(shell, theme)
        count = shell.buffer_manager&.dirty? ? shell.buffer_manager.dirty_files.size : 0
        count.zero? ? "temiz" : "#{count} #{theme.glyph(:dirty)}"
      end

      def sandbox_segment(shell)
        shell.config.fetch("sandbox.allow_network", false) ? "ağ-açık" : "izole"
      end
    end
  end
end
