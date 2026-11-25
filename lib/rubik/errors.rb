# frozen_string_literal: true

module Rubik
  # Root of the unified error taxonomy (issue #448, completed by #652):
  # every Rubik error class hangs off Rubik::Error so callers can rescue
  # one class. Standalone-requireable — submodule files that define
  # errors require this file instead of the full lib/rubik.rb entry
  # point.
  class Error < StandardError; end

  # Shared state-machine violation vocabulary (issue #448): the per-module
  # StateError classes (subagent Lifecycle, DeferredSpec, MCP BootLifecycle,
  # kernel Unit) subclass this, so rescuing Rubik::StateError catches any
  # guarded-transition tripwire without knowing the module.
  class StateError < Error; end
end
