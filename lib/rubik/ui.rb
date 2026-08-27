# frozen_string_literal: true

require_relative "ui/capability"
require_relative "ui/theme"
require_relative "ui/frame"
require_relative "ui/banner"
require_relative "ui/statusline"
require_relative "ui/spinner"
require_relative "ui/renderer"
require_relative "ui/markdown_stream"
require_relative "ui/approvals"
require_relative "ui/panel"
require_relative "ui/diff_viewer"

module Rubik
  # Terminal display layer (Plan 51): theme, capability detection, agent-flow
  # renderer, live spinner, markdown streaming and interactive approval /
  # panel surfaces. Registered into the Runtime as a coeffect service so
  # synthesized tools and plugins can resolve `ui` and `theme` through the
  # context, and so spinner threads are disposed with their context (LIFO
  # inverse), never leaked.
  module UI
    module RenderService
      module_function

      # Wires the display layer into the runtime context.
      # Returns the Renderer; also provides `ui` (renderer) and `theme`.
      # Idempotent on re-registration (`Shell#refresh_ui!`): service values
      # are swapped, the delete-inverses are not stacked, and the single
      # spinner-kill inverse resolves the CURRENT renderer at dispose time,
      # so repeated refreshes never grow the Omega accumulator.
      # `output:` lets callers bind to the real terminal when the shell's
      # current @output is a transient capture TeeIO.
      def register(context_or_manager, shell:, output: nil)
        ctx = context_or_manager.respond_to?(:context) ? context_or_manager.context : context_or_manager
        return nil unless ctx

        out = output || shell.output
        theme = Theme.for(out, shell.config)
        renderer = Renderer.new(config: shell.config, output: out, theme: theme)

        first_registration = !ctx.has?("ui")
        ctx.provide("ui", renderer)
        ctx.provide("theme", theme)
        ctx.on_dispose { (ctx.get("ui") || renderer)&.spinner&.kill } if first_registration

        context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)
        renderer
      end
    end
  end
end
