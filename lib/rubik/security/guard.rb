# frozen_string_literal: true

require_relative "audit_log"
require_relative "allowlist"
require_relative "command_gate"
require_relative "path_policy"
require_relative "synthesis_gate"

module Rubik
  module Security
    # Guard is now the delegating facade of the security stack (#403): it
    # composes the five deep modules (AuditLog → Allowlist / PathPolicy /
    # SynthesisGate / CommandGate) and preserves the historical one-object
    # contract for every caller — explicit delegating defs, spelled-out
    # kwargs, no method_missing — so duck-typed respond_to? checks
    # (config_wiring.rb, run_synthesis_gate) keep working on real methods.
    # The security-relevant bodies live in the modules; this file only
    # routes and holds the composition root (initialize + for_config).
    class Guard
      # Historical Guard:: constant surface, aliased to the module that now
      # owns each table — zero churn for tests and callers (the constants
      # are the same frozen objects, not copies).
      SYNTHESIS_CAPABILITIES             = SynthesisGate::SYNTHESIS_CAPABILITIES
      FORBIDDEN_SYNTHESIS_NODES          = SynthesisGate::FORBIDDEN_SYNTHESIS_NODES
      FORBIDDEN_SYNTHESIS_CALLS          = SynthesisGate::FORBIDDEN_SYNTHESIS_CALLS
      FORBIDDEN_SYNTHESIS_BARE_CALLS     = SynthesisGate::FORBIDDEN_SYNTHESIS_BARE_CALLS
      FORBIDDEN_SYNTHESIS_CONSTS         = SynthesisGate::FORBIDDEN_SYNTHESIS_CONSTS
      FORBIDDEN_SYNTHESIS_NETWORK_CONSTS = SynthesisGate::FORBIDDEN_SYNTHESIS_NETWORK_CONSTS
      DANGEROUS_SYNTHESIS_PATTERNS       = SynthesisGate::DANGEROUS_SYNTHESIS_PATTERNS
      DEFAULT_CRITICAL_PATTERNS          = PathPolicy::DEFAULT_CRITICAL_PATTERNS
      DANGEROUS_COMMAND_PATTERNS         = CommandGate::DANGEROUS_COMMAND_PATTERNS
      RAW_ALLOWLIST_UNSAFE_PATTERN       = Allowlist::RAW_ALLOWLIST_UNSAFE_PATTERN
      MASK_PATTERNS                      = AuditLog::MASK_PATTERNS

      def self.default_audit_log_path
        AuditLog.default_audit_log_path
      end

      # The one sanctioned way to build a policy-carrying Guard from operator
      # config (security.* keys). Composition root and Registry.build_default
      # both route through here so key names and disable-semantics live in
      # exactly one place.
      #
      # audit_log_path semantics: default ONLY when the key is absent. An
      # explicit nil (or blank string) DISABLES auditing — #log_audit already
      # suppresses on nil/empty. (The previous composition call site's
      # `fetch(...) || default` silently re-enabled auditing an operator had
      # turned off.)
      def self.for_config(config, root_dir: nil, shell: nil)
        return new if config.nil? || !config.respond_to?(:fetch)

        raw_audit = config.fetch("security.audit_log_path", default_audit_log_path)
        audit_path =
          case raw_audit
          when nil, "" then nil
          when String then raw_audit.strip.empty? ? nil : raw_audit
          else
            # Unconditional (not RUBIK_DEBUG-gated): Config's scalar parser
            # turns "!config set security.audit_log_path false" into boolean
            # false, which would otherwise reach log_audit and die in a
            # swallowed TypeError — silently dropping every audit event.
            warn "[Guard] security.audit_log_path has non-path value #{raw_audit.inspect}; auditing disabled"
            nil
          end

        effective_root = root_dir || (config.respond_to?(:root_dir) ? config.root_dir : nil)

        new(
          audit_log_path: audit_path,
          command_allowlist: Array(config.fetch("security.command_allowlist", [])),
          # Stringy "false" from persisted config must disable probes too.
          allow_safe_probes: config.fetch("security.allow_safe_probes", true).to_s.downcase != "false",
          root_dir: effective_root,
          shell: shell
        )
      end

      # Spawn-boundary entry: delegate to the module implementation with the
      # caller's guard injected — the duck-type check runs on it (facade
      # instances answer verify_synthesis_safety! through a real method).
      def self.run_synthesis_gate(guard, code)
        SynthesisGate.run_synthesis_gate(guard, code)
      end

      def self.synthesis_capability_layer(field)
        SynthesisGate.synthesis_capability_layer(field)
      end

      # Composition root: one shared AuditLog leaf, one Allowlist, one
      # PathPolicy, and the gates that consume them. The kwarg surface is
      # frozen (8 call sites + for_config).
      def initialize(custom_patterns: [], command_allowlist: [], allow_safe_probes: true,
                     audit_log_path: Guard.default_audit_log_path, root_dir: nil, shell: nil)
        @audit = AuditLog.new(audit_log_path)
        @allowlist = Allowlist.new(command_allowlist)
        @path_policy = PathPolicy.new(custom_patterns: custom_patterns, audit: @audit)
        @command_gate = CommandGate.new(
          allowlist: @allowlist,
          audit: @audit,
          path_policy: @path_policy,
          allow_safe_probes: allow_safe_probes,
          root_dir: root_dir,
          shell: shell
        )
        @synthesis_gate = SynthesisGate.new(audit: @audit)
      end

      # ── AuditLog (shared leaf) ──────────────────────────────────────────
      def audit_log_path
        @audit.audit_log_path
      end

      def audit_log_path=(val)
        @audit.audit_log_path = val
      end

      def mask_text(text)
        @audit.mask_text(text)
      end

      def log_audit(action, details = {})
        @audit.log_audit(action, details)
      end

      # ── Allowlist ────────────────────────────────────────────────────────
      def command_allowlist
        @allowlist.command_allowlist
      end

      def allowed_commands=(entries)
        @allowlist.allowed_commands = entries
      end
      alias set_allowed_commands allowed_commands=

      def command_allowlisted?(ast, cmd_str: nil)
        @allowlist.command_allowlisted?(ast, cmd_str: cmd_str)
      end

      # ── PathPolicy ───────────────────────────────────────────────────────
      def verify_path_write!(path)
        @path_policy.verify_path_write!(path)
      end

      def verify_root_safety!(path)
        @path_policy.verify_root_safety!(path)
      end

      # ── CommandGate (owns probe/root/shell state) ───────────────────────
      def shell
        @command_gate.shell
      end

      def shell=(val)
        @command_gate.shell = val
      end

      def root_dir
        @command_gate.root_dir
      end

      def root_dir=(val)
        @command_gate.root_dir = val
      end

      def allow_safe_probes?
        @command_gate.allow_safe_probes?
      end

      def allow_safe_probes=(val)
        @command_gate.allow_safe_probes = val
      end

      def verify_command_safety!(cmd, shell: nil, allow_unknown: false)
        @command_gate.verify_command_safety!(cmd, shell: shell, allow_unknown: allow_unknown)
      end

      def verify_command_fallback_regex!(cmd_str)
        @command_gate.verify_command_fallback_regex!(cmd_str)
      end

      # ── SynthesisGate ────────────────────────────────────────────────────
      def verify_synthesis_safety!(code)
        @synthesis_gate.verify_synthesis_safety!(code)
      end

      def synthesize_safety_walk(code_str)
        @synthesis_gate.synthesize_safety_walk(code_str)
      end
    end
  end
end
