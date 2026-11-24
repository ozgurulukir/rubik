# frozen_string_literal: true

module Rubik
  module Security
    CONTROL_ESCAPES = { "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\0" => "\\0", "\e" => "\\e" }.freeze
    CONTROL_CHAR_PATTERN = /[\x00-\x1F\x7F\u0080-\u009F]/

    # Escape control characters before command text reaches human- or
    # model-facing output (errors, warnings, approval prompts). Raw bytes still
    # drive classification, execution and the JSONL audit record. Shared so
    # every BlockedWriteError raise site renders identically (#638).
    def self.display_command(value)
      value.to_s.scrub.gsub(CONTROL_CHAR_PATTERN) do |ch|
        CONTROL_ESCAPES.fetch(ch) { format("\\x%02X", ch.ord) }
      end
    end

    # Carries structured context (command, rule name, probe-ness, block kind,
    # offending path) so callers can render situation-specific guidance
    # instead of regex-munging #message. Kept in its own file: consumers that
    # only rescue/raise the error (sandbox runner, buffer manager) must not
    # load the whole guard/classifier stack for the constant.
    class BlockedWriteError < StandardError
      attr_accessor :blocked_command, :rule_name, :probe_like, :kind, :path,
                    :segment_report, :classification_reason

      # Keyword form lets raise sites state every field up front (a field
      # cannot be forgotten). The attr_accessors (not just readers) keep the
      # error mutable for test fixtures and future live annotation — no lib
      # raise site needs the writers today.
      # segment_report: frozen plain Hash or nil, built by the Guard from the
      # classifier AST — {segments: [{display:, argv:, rule:, option:, reason:,
      # depth:}], safe: [String], wrapper_preview: String|nil,
      # allowlist_entries: [String]}. classification_reason: composed Engine
      # evidence for expression-level elevations (no segment report exists);
      # nil for per-command blocks. Plain data only: this file must stay
      # loadable without the guard/classifier stack.
      def initialize(message = nil, kind: nil, path: nil, blocked_command: nil,
                     rule_name: nil, probe_like: nil, segment_report: nil,
                     classification_reason: nil)
        super(message)
        @kind = kind
        @path = path
        @blocked_command = blocked_command
        @rule_name = rule_name
        @probe_like = probe_like
        @segment_report = segment_report
        @classification_reason = classification_reason
      end
    end
  end
end
