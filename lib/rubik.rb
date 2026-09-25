# frozen_string_literal: true

require_relative "rubik/version"
require_relative "rubik/platform"
require_relative "rubik/config"
require_relative "rubik/event_bus"
require_relative "rubik/repl"
require_relative "rubik/ui"
require_relative "rubik/buffer"
require_relative "rubik/session"
require_relative "rubik/context"
require_relative "rubik/ast"
require_relative "rubik/llm"
require_relative "rubik/adapter"
require_relative "rubik/diagnostics"
require_relative "rubik/tools"
require_relative "rubik/orchestrator"
require_relative "rubik/repair"
require_relative "rubik/security"
require_relative "rubik/sandbox"
require_relative "rubik/plugin"
require_relative "rubik/benchmark"
require_relative "rubik/lsp"
require_relative "rubik/mcp"
require_relative "rubik/runtime"
require_relative "rubik/skills"
require_relative "rubik/prompt"
require_relative "rubik/kernel/record"
require_relative "rubik/kernel/dmesg"
require_relative "rubik/kernel/dispatcher"

module Rubik
  class Error < StandardError; end

  class << self
    attr_accessor :current_shell, :runtime_manager

    # Deprecated read bridge (review Öneri 4 sunset): resolves the runtime
    # manager from the ambient root. New code must go through the context:
    # the 'shell' coeffect (Rubik::Coeffects::SHELL) via ctx.require or
    # Manager#context. Warns once per process.
    def runtime
      warn_ambient_read_once
      runtime_manager || current_shell&.runtime_manager
    end

    private

    def warn_ambient_read_once
      return if defined?(@ambient_warned) && @ambient_warned

      @ambient_warned = true
      warn "[DEPRECATION] Rubik.runtime is deprecated (sunset). Inject the " \
           "'shell' coeffect (Rubik::Coeffects::SHELL) or read the manager " \
           "from the owning Shell instead."
    end
  end
end
