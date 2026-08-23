# frozen_string_literal: true

require_relative "rubik/version"
require_relative "rubik/config"
require_relative "rubik/event_bus"
require_relative "rubik/repl"
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

module Rubik
  class Error < StandardError; end
end
