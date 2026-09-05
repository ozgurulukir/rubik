# frozen_string_literal: true

require_relative "../platform"

module Rubik
  module UI
    # Startup banner: brand, version, active model and quick hints inside a
    # rounded frame. Only rendered for interactive TTY sessions honoring
    # `ui.banner`; piped/scripted runs stay silent for clean automation.
    module Banner
      module_function

      def render(shell, theme)
        return nil unless shell.config.fetch("ui.banner", true)
        return nil unless Capability.interactive?(input: shell.input, output: shell.output)

        routed = Statusline.current_route(shell)
        model = routed ? Statusline.model_label(routed) : "model yapılandırılmamış"
        project = File.basename(shell.buffer_manager&.root_dir || Dir.pwd)
        branch = shell.detect_git_branch || "no-git"

        lines = [
          "🎲 Rubik v#{Rubik::VERSION}",
          theme.paint(model, :info),
          theme.paint("#{project} · #{branch}", :dim),
          theme.paint("!help komutlar · ctrl+c kes · !config ayarlar", :dim)
        ]

        if Rubik::Platform.linux? && Rubik::Platform.which("bwrap") &&
           !shell.config.fetch("sandbox.enabled", false) &&
           shell.config.fetch("sandbox.prompt_on_startup", true)
          lines << theme.paint("💡 Linux & bwrap algılandı: '!sandbox on' ile donanımsal OS izolasyonu açılabilir", :yellow)
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
