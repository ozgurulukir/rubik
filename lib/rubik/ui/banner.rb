# frozen_string_literal: true

require_relative "../platform"
require_relative "../storage/layout"

module Rubik
  module UI
    # Startup banner: brand, version, active model and quick hints inside a
    # rounded frame. Only rendered for interactive TTY sessions honoring
    # `ui.banner`; piped/scripted runs stay silent for clean automation.
    module Banner
      module_function

      def render(shell, theme)
        return nil unless Rubik::Storage::Layout.config_get(shell.config, "ui.banner", true)
        return nil unless Capability.interactive?(input: shell.input, output: shell.output)

        routed = Statusline.current_route(shell)
        model = routed ? Statusline.model_label(routed) : "model not configured"
        project = File.basename(shell.buffer_manager&.root_dir || Dir.pwd)
        branch = shell.detect_git_branch || "no-git"

        lines = [
          "🎲 Rubik v#{Rubik::VERSION}",
          theme.paint(model, :info),
          theme.paint("#{project} · #{branch}", :dim),
          theme.paint("!help commands · ctrl+c interrupt · !config settings", :dim)
        ]

        if Rubik::Platform.linux? && Rubik::Platform.which("bwrap") &&
           !Rubik::Storage::Layout.config_get(shell.config, "sandbox.enabled", false) &&
           Rubik::Storage::Layout.config_get(shell.config, "sandbox.prompt_on_startup", true)
          lines << theme.paint("💡 Linux & bwrap detected: hardware OS isolation can be enabled with '!sandbox on'", :warn)
        end

        Frame.draw(
          lines,
          theme: theme,
          title: theme.paint("rubik", :accent)
        )
      end
    end
  end
end
