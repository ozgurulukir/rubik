# frozen_string_literal: true

module Rubik
  module Security
    # Carries structured context (command, rule name, probe-ness, block kind,
    # offending path) so callers can render situation-specific guidance
    # instead of regex-munging #message. Kept in its own file: consumers that
    # only rescue/raise the error (sandbox runner, buffer manager) must not
    # load the whole guard/classifier stack for the constant.
    class BlockedWriteError < StandardError
      attr_accessor :blocked_command, :rule_name, :probe_like, :kind, :path

      # Keyword form lets raise sites state every field up front (a field
      # cannot be forgotten). The attr_accessors (not just readers) keep the
      # error mutable for test fixtures and future live annotation — no lib
      # raise site needs the writers today.
      def initialize(message = nil, kind: nil, path: nil, blocked_command: nil,
                     rule_name: nil, probe_like: nil)
        super(message)
        @kind = kind
        @path = path
        @blocked_command = blocked_command
        @rule_name = rule_name
        @probe_like = probe_like
      end
    end
  end
end
