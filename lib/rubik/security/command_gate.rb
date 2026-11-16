# frozen_string_literal: true

require "shellwords"
require_relative "../log"
require_relative "allowlist"
require_relative "classifier"
require_relative "errors"
require_relative "segment_report"

module Rubik
  module Security
    # The shell-command gate, split out of Guard (#403): verdicts on shell
    # command strings — classifier orchestration, the safe-probe exemption,
    # workspace-trust recognition, interactive operator approval, the
    # un-bypassable catastrophic fallback regex, and the blocked-segment
    # guidance evidence. Owns the live-reconfigurable probe/root/shell
    # state; allowlist verdicts delegate to the injected Allowlist,
    # critical-path writes to the injected PathPolicy, and every decision
    # is audit-logged through the injected AuditLog.
    class CommandGate
      # Pipe-to-interpreter (the curl|bash RCE shape). This pattern lives in
      # the UN-BYPASSABLE fallback gate: verify_command_fallback_regex! runs
      # even on allowlisted and safe-probe commands, so anything it matches
      # cannot be allowlisted away — keep any widening surgical. The
      # intermediaries between the pipe and the interpreter are flag-less
      # (sudo bash, env sh); flag-bearing forms (sudo -u root bash) are
      # already blocked earlier by the AST classifier's delegation rules
      # when it is healthy, so the fallback does not need to cover them.
      # Word boundaries on both ends also stop substring matches like
      # "mycurl ... | sh" or "| shadowtool".
      PIPE_TO_INTERPRETER_PATTERN = /
        \b(?:curl|wget)\b.*\|\s*
        (?:(?:sudo|doas|env|nohup|nice|stdbuf|xargs)\s+)*
        (?:bash|zsh|dash|ksh|fish|sh|pwsh|python\d?|ruby|perl|node|php|lua)\b
      /xi

      DANGEROUS_COMMAND_PATTERNS = [
        Regexp.new(
          'rm\s+(?:-[a-z0-9-]+\s+)*(?:-[a-z0-9]*r[a-z0-9]*f[a-z0-9]*|-[a-z0-9]*f[a-z0-9]*r[a-z0-9]*|' \
          '(?:(?:-[a-z0-9]*r[a-z0-9]*|--recursive)\s+(?:-[a-z0-9]*f[a-z0-9]*|--force))|' \
          '(?:(?:-[a-z0-9]*f[a-z0-9]*|--force)\s+(?:-[a-z0-9]*r[a-z0-9]*|--recursive)))' \
          '\s+(?:-[a-z0-9-]+\s+)*(?:--\s+)?/(?:\*|\.+(?![a-zA-Z0-9_-])|(?![a-zA-Z0-9_.-]))',
          Regexp::IGNORECASE
        ),
        PIPE_TO_INTERPRETER_PATTERN,
        /:\(\)\{\s*:\|:&\s*\};:/, # fork bomb
        %r{\bdd\s+.*(?:if=|of=/dev/)}i,
        /\bmkfs(?:\.\w+)?\b/i,
        /\b(?:shutdown|reboot|poweroff|halt)\b(?:\s+.*)?/i,
        /\b(?:Format-Volume|Clear-Disk|Initialize-Disk|Remove-Partition|Stop-Computer|Restart-Computer)\b/i,
        /\bdiskpart\b/i,
        /\brm\s+.*--no-preserve-root/i,
        %r{del\s+.*/s.*[a-z]:\\}i,
        %r{erase\s+.*/s.*[a-z]:\\}i,
        %r{rmdir\s+.*/s.*[a-z]:\\}i,
        %r{rd\s+.*/s.*[a-z]:\\}i,
        /format\s+[a-z]:/i,
        /Remove-Item\s+.*-Recurse.*[a-z]:\\/i,
        /%0\|%0/
      ].freeze

      # Salt version/help probe'ları (Plan: safe-probe muafiyeti): a command
      # whose ONLY arguments are these flags is read-only by construction.
      SAFE_PROBE_FLAGS = ["--version", "-v", "--help", "-h"].freeze

      attr_accessor :shell, :root_dir

      def initialize(allowlist:, audit:, path_policy:, allow_safe_probes: true,
                     root_dir: nil, shell: nil)
        @allowlist = allowlist
        @audit = audit
        @path_policy = path_policy
        @allow_safe_probes = allow_safe_probes == true
        @root_dir = root_dir
        @shell = shell
      end

      def workspace_trust_candidate_allowed?(cmd_str, ast = nil)
        return false if cmd_str.to_s.match?(Allowlist::RAW_ALLOWLIST_UNSAFE_PATTERN)

        ast ||= begin
          Rubik::Security::Classifier.classify(cmd_str.to_s)
        rescue StandardError
          nil
        end
        return false unless ast
        return false if ast.respond_to?(:parse_warnings) && ast.parse_warnings.to_a.any?
        return false unless ast.respond_to?(:commands) && ast.commands.to_a.size == 1

        cmd = ast.commands.first
        return false if cmd.respond_to?(:inner_commands) && cmd.inner_commands && !cmd.inner_commands.empty?

        effective_root = @root_dir || Dir.pwd
        return false unless defined?(Rubik::CLI::WorkspaceTrust) && Rubik::CLI::WorkspaceTrust.trusted?(effective_root)
        return false unless defined?(Rubik::Runtime::Discovery)

        Rubik::Runtime::Discovery.recognized_candidate?(cmd_str, root_dir: effective_root)
      end

      # security.allow_safe_probes — operator-managed toggle (live-reconfigurable
      # via ConfigWiring, zero restart). Default ON.
      def allow_safe_probes?
        @allow_safe_probes
      end

      def allow_safe_probes=(val)
        # Accept both booleans and stringy config values ("true"/"false").
        @allow_safe_probes = val == true || val.to_s.downcase == "true"
      end

      # True when the command's arguments are exclusively version/help flags
      # (e.g. `bash --version`, `node -v`, `git --help`); no other arguments.
      # Gate is the operator toggle; shape detection lives in probe_shape? so
      # blocked-error annotation can label probe-shaped commands even when the
      # exemption is disabled — otherwise the variant-(a) probe guidance would
      # be unreachable (a probe only reaches the block path when disabled).
      def safe_probe?(cmd_str)
        return false unless @allow_safe_probes

        probe_shape?(cmd_str)
      end

      def probe_shape?(cmd_str)
        str = cmd_str.to_s
        return false if str.match?(/[\r\n]/)

        tokens = shell_tokens(str)
        return false unless tokens
        return false if tokens.size < 2

        tokens[1..].all? { |t| SAFE_PROBE_FLAGS.include?(t) }
      end

      # allow_unknown: synthesis verification no longer routes through the
      # shell gate (it has its own deny layers: DANGEROUS_SYNTHESIS_PATTERNS
      # + AST walk), so no production caller passes true today. The flag
      # remains a tested seam for future in-gate verifiers of non-shell
      # source; shell-gate callers must keep the default: an UNKNOWN verdict
      # means an unvetted binary, and a binary the database cannot classify
      # is exactly the one that must not run without operator approval.
      def verify_command_safety!(cmd, shell: nil, allow_unknown: false)
        cmd_str = cmd.to_s
        begin
          ast = Rubik::Security::Classifier.classify(cmd_str, shell: shell)
          @path_policy.check_critical_path_writes!(ast, cmd_str)
          if ast.classification == :dangerous
            # Safe-probe exemption (highest-priority friction fix): run the
            # catastrophic fallback regex first — it never loosens.
            # Strictly single, isolated command without inner commands or chains.
            if isolated_single_command?(ast) && safe_probe?(cmd_str)
              verify_command_fallback_regex!(cmd_str)
              @audit.log_audit("safe_probe", command: cmd_str, reason: "safe_probe_exemption")
              return true
            end
            walk_reason = dangerous_reason(ast.commands)
            # Expression-level elevation marks no single command dangerous —
            # the per-command walk bottoms out at its sentinel while the
            # composed evidence travels on the ExpressionResult itself.
            expression_reason = walk_reason == "dangerous_ast" ? expression_level_reason(ast) : nil
            return true if operator_allowlist_pass?(ast, cmd_str)

            block_dangerous_command!(ast, cmd_str, reason: expression_reason || walk_reason, expression_reason: expression_reason)
          end

          # UNKNOWN is fail-closed, not pass-through: the matcher rates every
          # database-less binary unknown/high, so letting it fall through to
          # the catastrophic-only regex would run `socat`/`nmap`/any unlisted
          # tool with zero approval while the tool copy advertises fail-closed.
          # Allowlist rescue unchanged (every top-level segment must match).
          # No safe-probe exemption: an unknown binary's --version still
          # executes an unvetted binary — the allowlist is the valve.
          if ast.classification == :unknown && !allow_unknown
            return true if operator_allowlist_pass?(ast, cmd_str)

            # Workspace Trust Discovery Recognition Gate:
            if workspace_trust_candidate_allowed?(cmd_str, ast)
              @audit.log_audit("allowed_command", command: cmd_str, reason: "workspace_trust_discovery")
              verify_command_fallback_regex!(cmd_str)
              return true
            end

            # Interactive operator approval gate (Antigravity-style single keypress)
            return true if operator_interactive_approval?(cmd_str, shell)

            block_unknown_command!(cmd_str)
          end

          # Ambiguous parse (tree-sitter syntax errors) is a classification
          # failure, not a pass: the walk cannot vouch for the whole
          # expression, so a safe-looking partial verdict must not fall
          # through to the catastrophic-only regex gate. The allowlist stays
          # the valve because a real AST exists — every segment is checked
          # against the operator entries.
          if !allow_unknown && ast.parse_warnings.to_a.any?
            return true if operator_allowlist_pass?(ast, cmd_str)

            block_ambiguous_parse!(ast, cmd_str)
          end
        rescue BlockedWriteError
          raise
        rescue StandardError => e
          # Unconditional warn + audit trail: a classifier crash is a
          # security-observable downgrade nobody should need RUBIK_DEBUG to
          # notice. The shell gate fails closed — an exception must never
          # mint execution permission; the operator allowlist is the one
          # sanctioned valve. The allow_unknown seam (no production caller
          # today) keeps flowing into its own deny layers
          # (DANGEROUS_SYNTHESIS_PATTERNS + RubyVM walk) after this gate.
          if allow_unknown
            Rubik::Log.warn(:security, "[WARN] AST classification error on non-shell input, continuing to synthesis deny layers: #{e.message}")
            @audit.log_audit("classifier_error", command: cmd_str, reason: "#{e.class}: #{e.message}",
                                                 decision: "synthesis_layers")
          else
            Rubik::Log.warn(:security, "[WARN] AST classification error, failing closed: #{e.class}: #{e.message}")
            block_on_classifier_failure!(cmd_str, e)
          end
        end

        verify_command_fallback_regex!(cmd_str)
      end

      def verify_command_fallback_regex!(cmd_str)
        return true unless DANGEROUS_COMMAND_PATTERNS.any? { |p| cmd_str.match?(p) }

        @audit.log_audit("blocked_command", command: cmd_str, reason: "dangerous_pattern")
        raise BlockedWriteError.new(
          "Dangerous command execution blocked: #{cmd_str}",
          kind: :dangerous_pattern,
          blocked_command: cmd_str,
          rule_name: "dangerous_pattern"
        )
      end

      private

      # Shellword tokenization for probe-shape detection; nil when the string
      # has none (unbalanced quotes). The caller fails closed on nil rather
      # than guessing with whitespace splitting — a quote-corrupted command
      # (rm "--version) must not shape as a read-only probe.
      def shell_tokens(str)
        Shellwords.split(str)
      rescue ArgumentError
        nil
      end

      # Single home for the operator allowlist valve, evaluated fail-closed:
      # a bug in the gate itself must deny, never pass, and must stay loud on
      # $stderr — a security-observable downgrade nobody should need
      # RUBIK_DEBUG to notice. The catastrophic fallback regex still runs
      # after every allowlisted pass; allowlisting never bypasses it.
      # raw: the classifier-crash gate authorizes against the raw command
      # string because no AST exists to evaluate.
      def allowlisted_fail_closed(ast, cmd_str, raw: false)
        if raw
          @allowlist.command_allowlisted_raw?(cmd_str)
        else
          @allowlist.command_allowlisted?(ast, cmd_str: cmd_str)
        end
      rescue StandardError => e
        Rubik::Log.warn(:security, "[Guard] #{'raw ' if raw}allowlist evaluation failed, failing closed: #{e.class}: #{e.message}")
        false
      end

      # AST fast-path check for the safe-probe exemption: strictly single,
      # isolated command without inner commands or chains.
      def isolated_single_command?(ast)
        ast.respond_to?(:commands) && ast.commands.to_a.size == 1 &&
          ast.respond_to?(:parse_warnings) && ast.parse_warnings.to_a.empty? &&
          (!ast.commands.first.respond_to?(:inner_commands) || ast.commands.first.inner_commands.nil? || ast.commands.first.inner_commands.empty?)
      end

      # Operator allowlist valve pass, shared by the dangerous / unknown /
      # ambiguous-parse block paths. Fail-closed default: the entry must
      # cover EVERY dangerous segment recursively; catastrophic fallback
      # regex still runs afterwards — allowlisting never bypasses it.
      # A bug in the gate itself must fail closed, not fall through to
      # the regex-only downgrade below. Returns true only after the
      # allowed_command audit and the fallback regex have run.
      def operator_allowlist_pass?(ast, cmd_str)
        return false unless allowlisted_fail_closed(ast, cmd_str)

        @audit.log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist")
        verify_command_fallback_regex!(cmd_str)
        true
      end

      # Report assembly for the dangerous-classification block path, fail-soft
      # to nil: enrichment must never be able to un-block, so a bug in the
      # report walk downgrades to nil here and the raise in
      # block_dangerous_command! still fires.
      # Report assembly delegates to Security::SegmentReport (#500), fail-soft
      # to nil: enrichment must never be able to un-block, so a bug in the
      # report walk downgrades to nil here and the raise in
      # block_dangerous_command! still fires.
      def dangerous_segment_report_or_nil(commands)
        SegmentReport.build(commands)
      rescue StandardError => e
        Rubik::Log.warn(:security, "[Guard] segment report failed: #{e.class}: #{e.message}")
        nil
      end

      # Dangerous-classification block path: audit the block, then raise with
      # the blocked-segment guidance report attached.
      def block_dangerous_command!(ast, cmd_str, reason:, expression_reason:)
        report = dangerous_segment_report_or_nil(ast.commands)
        @audit.log_audit("blocked_command", command: cmd_str, reason: reason,
                                            dangerous_segments: segment_count(report))
        # probe_shape? (not safe_probe?): probes only reach this raise when
        # the exemption is disabled, so safe_probe? would be constantly
        # false and the variant-(a) probe guidance would be dead code.
        raise BlockedWriteError.new(
          "Dangerous command execution blocked: #{cmd_str} (reason: #{reason})",
          kind: :dangerous_command,
          blocked_command: cmd_str,
          rule_name: dangerous_rule_name(ast.commands) || (expression_reason ? "expression_level" : "dangerous_pattern"),
          probe_like: probe_shape?(cmd_str),
          segment_report: report,
          classification_reason: expression_reason
        )
      end

      # Interactive operator approval gate (Antigravity-style single keypress):
      # true (audited) when the operator approves, false when there is no
      # interactive input or the answer is not yes.
      def operator_interactive_approval?(cmd_str, shell)
        effective_shell = shell || @shell
        return false unless effective_shell.respond_to?(:interactive_input?) && effective_shell.interactive_input?

        # Defense-in-depth: Un-bypassable catastrophic fallback regex MUST pass before prompt
        verify_command_fallback_regex!(cmd_str)

        theme = (effective_shell.respond_to?(:ui_theme) && effective_shell.ui_theme) ||
                (defined?(Rubik::UI::Theme) ? Rubik::UI::Theme.new : nil)

        question = "Allow unclassified command execution: '#{cmd_str}'?"
        answer = if defined?(Rubik::UI::Approvals)
                   Rubik::UI::Approvals.keypress_yes_no(effective_shell, question, theme: theme, default: "n")
                 else
                   "n"
                 end

        return false unless ["y", "yes"].include?(answer.to_s.downcase)

        @audit.log_audit("allowed_command", command: cmd_str, reason: "operator_interactive_approval")
        true
      end

      def block_unknown_command!(cmd_str)
        @audit.log_audit("blocked_command", command: cmd_str, reason: "unknown_command")
        raise BlockedWriteError.new(
          "Unknown command execution blocked (fail-closed): #{cmd_str}. The binary is not in the " \
          "command database, so its effects cannot be classified. If it is genuinely safe, the " \
          "operator can allowlist the exact prefix: !allow-cmd add \"<binary> [args]\"",
          kind: :unknown_command,
          blocked_command: cmd_str,
          rule_name: "unknown_command",
          probe_like: probe_shape?(cmd_str),
          segment_report: nil
        )
      end

      def block_ambiguous_parse!(ast, cmd_str)
        @audit.log_audit("blocked_command", command: cmd_str, reason: "parse_ambiguous",
                                            parse_warnings: ast.parse_warnings.to_a.size)
        raise BlockedWriteError.new(
          "Command AST could not be fully parsed (tree-sitter syntax error); execution blocked (fail-closed): #{cmd_str}",
          kind: :parse_ambiguous,
          blocked_command: cmd_str,
          rule_name: "parse_ambiguous",
          probe_like: probe_shape?(cmd_str),
          segment_report: nil
        )
      end

      def dangerous_reason(commands)
        commands.each do |c|
          next unless c.classification == :dangerous

          # Dangerous INNERS only: recursing into safe inners would shadow
          # the command's own reason with the "dangerous_ast" sentinel —
          # which must stay exclusive to expression-level elevations (the
          # raise site uses it as the expression-case signal).
          inner = nil
          inner = dangerous_reason(c.inner_commands) if c.respond_to?(:inner_commands) && c.inner_commands&.any? { |i| i.classification == :dangerous }
          return inner || (c.respond_to?(:classification_reason) && c.classification_reason) || "dangerous_command"
        end
        "dangerous_ast"
      end

      # Innermost dangerous segment's rule name — surfaced in blocked-command
      # guidance so the operator knows exactly which rule matched and what
      # prefix to allowlist (e.g. rule: bash, rule: rm).
      def dangerous_rule_name(commands)
        commands.each do |c|
          next unless c.classification == :dangerous

          inner = dangerous_rule_name(c.inner_commands) if c.respond_to?(:inner_commands) && c.inner_commands&.any?
          return inner || (c.respond_to?(:matched_rule) && c.matched_rule)
        end
        nil
      end

      # Expression-level elevations (Engine#build_expression_result) are
      # dangerous with no dangerous command to name — the composed evidence
      # rides on the ExpressionResult itself. Presence (non-nil) is the
      # expression-case signal.
      def expression_level_reason(ast)
        return nil unless ast.respond_to?(:classification_reason)

        reason = ast.classification_reason.to_s.strip
        reason.empty? ? nil : reason
      end

      def segment_count(report)
        report ? report[:segments].size : 0
      end

      # Classifier-crash gate for the shell path: structured block by
      # default, one sanctioned rescue — an operator allowlist entry
      # covering the exact single-command prefix (the same explicit
      # authorization contract as the unknown-command gate). The
      # catastrophic fallback regex still runs afterwards on the rescue
      # path; on the block path it gets first refusal so a catastrophic
      # command keeps its precise :dangerous_pattern reason.
      def block_on_classifier_failure!(cmd_str, error)
        allowlisted = allowlisted_fail_closed(cmd_str, cmd_str, raw: true)
        @audit.log_audit("classifier_error", command: cmd_str, reason: "#{error.class}: #{error.message}",
                                             decision: allowlisted ? "operator_allowlist" : "blocked")

        if allowlisted
          @audit.log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist_classifier_error")
          return
        end

        verify_command_fallback_regex!(cmd_str)
        @audit.log_audit("blocked_command", command: cmd_str, reason: "classifier_error")
        raise BlockedWriteError.new(
          "AST evaluation failed, so the command could not be classified; execution blocked (fail-closed): #{cmd_str}",
          kind: :classifier_error,
          blocked_command: cmd_str,
          rule_name: "classifier_error",
          probe_like: probe_shape?(cmd_str),
          segment_report: nil
        )
      end
    end
  end
end
