# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "../platform"
require_relative "redactor"

module Rubik
  module Security
    # The shared audit leaf of the Guard split (#403): owns the audit
    # destination (@audit_log_path), secret masking, and the JSONL append.
    # Every other security module (PathPolicy, CommandGate, SynthesisGate)
    # receives an instance of this class and routes its log_audit calls
    # through it — the audit trail has exactly one home.
    class AuditLog
      MASK_PATTERNS = Rubik::Security::Redactor::PATTERNS

      attr_reader :audit_log_path

      # Default audit location, resolved at call time (not a load-time
      # constant) so Platform.home_dir stubs in tests and runtime HOME
      # changes are honored. Single source shared by the constructor
      # default and Guard.for_config.
      def self.default_audit_log_path
        File.join(Rubik::Platform.home_dir, ".rubik", "audit.log")
      end

      def initialize(audit_log_path = AuditLog.default_audit_log_path)
        @audit_log_path = audit_log_path
      end

      # Live-reconfigurable audit destination (ConfigWiring applies config
      # changes in place — zero restart). Same blank-means-disabled semantics
      # as for_config; non-string values pass through and surface loudly in
      # log_audit's unconditional warn.
      def audit_log_path=(val)
        @audit_log_path = val.is_a?(String) && val.strip.empty? ? nil : val
      end

      def mask_text(text)
        Rubik::Security::Redactor.redact(text)
      end

      def log_audit(action, details = {})
        return if @audit_log_path.nil? || @audit_log_path.to_s.strip.empty?

        # Nil-safety: a nil details hash (or nil value) must never crash the
        # command path — audit failure is already swallowed below.
        masked_details = (details || {}).transform_values { |v| v.nil? ? "" : mask_text(v.to_s) }

        entry = {
          ts: Time.now.iso8601,
          action: action,
          details: masked_details
        }

        dir = File.dirname(@audit_log_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)

        File.open(@audit_log_path, "a") do |f|
          f.puts(JSON.dump(entry))
        end
      rescue StandardError => e
        # Unconditional: an audit trail failing silently is indistinguishable
        # from an operator's intentional disable — the one warn in the guard
        # that must not hide behind RUBIK_DEBUG.
        warn "[WARN] Failed to write audit log #{@audit_log_path}: #{e.message}"
      end
    end
  end
end
