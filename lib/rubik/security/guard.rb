# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "shellwords"
require_relative "../platform"
require_relative "classifier"
require_relative "errors"
require_relative "redactor"

module Rubik
  module Security
    class Guard
      DEFAULT_CRITICAL_PATTERNS = [
        ".git/**",
        ".env*",
        "secrets.*",
        "*.pem",
        "*.key",
        "id_rsa*"
      ].freeze

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

      # Display caps for the blocked-segment report (guidance rendering, not
      # gate semantics): one segment's argv rendering and the one-line
      # wrapper preview never exceed these.
      SEGMENT_DISPLAY_CAP = 120
      WRAPPER_PREVIEW_CAP = 60

      # Synth-unsafe patterns. These catch RCE-y escapes a synthesis step might
      # smuggle past the classifier (tuned for shell commands, not Ruby):
      # `method(:x).call`, variable send/public_send/__send__, eval/binding.eval,
      # and backticks/%x. The interpreter/eval lines precede the backtick and %x
      # patterns so strings merely *mentioning* backticks aren't mislabelled.
      # Symbol-level denials live in SYNTHESIS_CAPABILITIES below; the two
      # layers are equivalence-locked by test_synthesis_capability_coverage.rb.
      DANGEROUS_SYNTHESIS_PATTERNS = [
        /\b(?:send|public_send|__send__)\s*[( \s]/,
        /\.(?:send|public_send|__send__)\b/,
        /\b(?:method|public_method|singleton_method)\s*(?:\(\s*[:"']|\s+[:"'])/i,
        /\beval\s*[( \s]/,
        /\bbinding\s*\.\s*eval\b/i,
        /\b(?:instance_eval|class_eval|module_eval)\b/,
        /\b(?:instance_variable_get|instance_variable_set)\b/,
        /\b(?:const_set|const_get|remove_const)\b/,
        /(?:^|[;{\n\r])\s*(?:system|exec|spawn)\b|\b(?:system|exec|spawn)\s*\(/,
        /(?:^|[;{\n\r])\s*fork\b|\bfork\s*(?:do|\{|\()/,
        /\bsyscall\s*\(/,
        /\bexit!/,
        /\bIO\s*\.\s*popen\b/,
        /\bOpen3\s*\.\s*(?:capture2|capture2e|capture3|popen2|popen2e|popen3|pipeline)\b/,
        /\bProcess\s*\.\s*(?:kill|fork|daemon|spawn|exec)\b/,
        /\bKernel\s*\.\s*(?:exec|system|fork|spawn|syscall|exit!)\b/,
        # Unmanaged background threads survive context disposal — the exact
        # "Leaked Side Effects" anti-pattern (AGENTS.md §5).
        /\bThread\s*\.\s*(?:new|fork|start)\b/,
        /`[^`]*`/,
        Regexp.new('%x\s*[({\[<|/]', Regexp::IGNORECASE)
      ].freeze

      DANGEROUS_SYSTEM_ROOTS = [
        "/", "/root", "/home", "/etc", "/usr", "/var", "/bin", "/sbin", "/lib", "/lib64", "/opt", "/boot", "/dev", "/proc", "/sys"
      ].freeze

      MASK_PATTERNS = Rubik::Security::Redactor::PATTERNS

      # Salt version/help probe'ları (Plan: safe-probe muafiyeti): a command
      # whose ONLY arguments are these flags is read-only by construction.
      SAFE_PROBE_FLAGS = ["--version", "-v", "--help", "-h"].freeze

      # Shell metacharacters that make a raw (AST-less) token-prefix allowlist
      # match dishonest: they can join, redirect, substitute, or line-split
      # the string, so "the first tokens match" would not mean "the whole
      # simple command matches". The classifier-crash rescue only accepts a
      # single simple command; anything else fails closed.
      RAW_ALLOWLIST_UNSAFE_PATTERN = /[;&|<>`$(){}\[\]\\\n\r]/

      attr_reader :audit_log_path

      # Live-reconfigurable audit destination (ConfigWiring applies config
      # changes in place — zero restart). Same blank-means-disabled semantics
      # as for_config; non-string values pass through and surface loudly in
      # log_audit's unconditional warn.
      def audit_log_path=(val)
        @audit_log_path = val.is_a?(String) && val.strip.empty? ? nil : val
      end

      # Default audit location, resolved at call time (not a load-time
      # constant) so Platform.home_dir stubs in tests and runtime HOME
      # changes are honored. Single source shared by the constructor
      # default and for_config.
      def self.default_audit_log_path
        File.join(Rubik::Platform.home_dir, ".rubik", "audit.log")
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
      def self.for_config(config)
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
        new(
          audit_log_path: audit_path,
          command_allowlist: Array(config.fetch("security.command_allowlist", [])),
          # Stringy "false" from persisted config must disable probes too.
          allow_safe_probes: config.fetch("security.allow_safe_probes", true).to_s.downcase != "false"
        )
      end

      def initialize(custom_patterns: [], command_allowlist: [], allow_safe_probes: true,
                     audit_log_path: Guard.default_audit_log_path)
        @critical_patterns = (DEFAULT_CRITICAL_PATTERNS + custom_patterns).uniq
        @command_allowlist = normalize_allowlist(command_allowlist)
        @allow_safe_probes = allow_safe_probes == true
        @audit_log_path = audit_log_path
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

        tokens = begin
          Shellwords.split(str)
        rescue ArgumentError
          str.split(/\s+/)
        end
        return false if tokens.size < 2

        tokens[1..].all? { |t| SAFE_PROBE_FLAGS.include?(t) }
      end

      # Operator-controlled command allowlist (Plan: komut-allowlist-güvenlik-kapısı).
      # Entries are token-prefixes: "node" allows every node invocation (broad);
      # "node .gitnexus/run.cjs" allows only that script (narrow — preferred).
      # Applied AFTER classifier verdict, BEFORE the raise, and the catastrophic
      # fallback regex still runs afterwards (defense-in-depth is never skipped).
      def command_allowlist
        @command_allowlist.dup
      end

      def allowed_commands=(entries)
        @command_allowlist = normalize_allowlist(entries)
      end
      alias set_allowed_commands allowed_commands=

      def command_allowlisted?(ast, cmd_str: nil)
        _ = cmd_str
        return false if @command_allowlist.empty?
        return false unless ast.respond_to?(:commands)

        ast_commands = ast.commands.to_a
        return false if ast_commands.empty?

        # EVERY dangerous segment (recursively incl. pipeline inner commands)
        # must match an entry — a single allowlisted prefix cannot rescue
        # `allowlisted-cmd && rm -rf /` chains.
        ast_commands.all? { |c| command_matches_allowlist?(c) }
      end

      private

      def normalize_allowlist(entries)
        Array(entries).filter_map do |e|
          tokens = e.to_s.strip.split(/\s+/).reject(&:empty?)
          tokens unless tokens.empty?
        end
      end

      def canonical_binary_path(bin)
        return nil if bin.nil? || bin.to_s.empty?

        str = bin.to_s
        if str.include?("/") || str.include?("\\") || File.exist?(str)
          Rubik::Platform.normalize_path(File.expand_path(str))
        else
          resolved = Rubik::Platform.which(str)
          resolved ? Rubik::Platform.normalize_path(resolved) : nil
        end
      end

      def binary_allowlist_match?(arg, token)
        return true if arg == token
        # Windows exe-alias fast path (#103): on a windows host "node.exe"
        # IS the allowlisted "node" — a lexical alias, no filesystem probe.
        # The canonical-path probe below resolves through Platform.which +
        # File.file?, a second host seam the windows? stub cannot cover (a
        # linux host has no node.exe on disk, so the probe fails and the
        # allowlist would dead-close). On a posix host the alias is FALSE:
        # node.exe is a different binary than node there.
        return true if windows_executable_alias?(arg, token)

        c_arg = canonical_binary_path(arg)
        c_token = canonical_binary_path(token)

        return true if c_arg && c_token && Rubik::Platform.path_equal?(c_arg, c_token)

        false
      end

      # True when arg carries an executable extension from PATHEXT and its
      # stem equals the token (case-insensitive — windows path semantics).
      # Bare stems only: a path-form arg ("C:/x/node.exe") keeps going
      # through the canonical-path probe, which resolves both sides.
      def windows_executable_alias?(arg, token)
        return false unless Rubik::Platform.windows?

        ext = ::File.extname(arg)
        return false if ext.empty? || !Rubik::Platform.pathext.include?(ext.downcase)

        arg.delete_suffix(ext).casecmp?(token)
      end

      def command_matches_allowlist?(result)
        # Missing argv (e.g. empty invocation) can never be allowlisted.
        argv = result.respond_to?(:argv) ? result.argv : nil
        return false if argv.nil? || argv.empty?

        # Dangerous shell builtins (`source`, `.`) are never rescuable by
        # allowlist: they execute arbitrary file content by design.
        binary = argv[0].to_s
        return false if Rubik::Security::Classifier::Matcher::BUILTIN_DANGEROUS_CMDS.include?(binary)

        # W6: If this command wraps inner commands, EVERY inner command must also match allowlist
        if result.respond_to?(:inner_commands) && result.inner_commands && !result.inner_commands.empty? && !result.inner_commands.all? do |inner|
          command_matches_allowlist?(inner)
        end
          return false
        end

        @command_allowlist.any? do |entry|
          next false if entry.length > argv.length

          entry.each_with_index.all? do |token, i|
            arg = argv[i]
            if i.zero?
              binary_allowlist_match?(arg, token)
            else
              arg == token
            end
          end
        end
      end

      public

      def verify_path_write!(path)
        return true if path.nil? || path.to_s.strip.empty?

        raw = Rubik::Platform.normalize_path_raw(path.to_s)
        expanded = Rubik::Platform.normalize_path_raw(File.expand_path(path.to_s))

        # Check raw relative path, expanded path, and relative-from-pwd
        candidates = [raw, expanded]
        begin
          pwd_raw = Rubik::Platform.normalize_path_raw(Dir.pwd)
          candidates << expanded.delete_prefix("#{pwd_raw}/") if expanded.start_with?("#{pwd_raw}/")
        rescue SystemCallError, ArgumentError
          nil
        end

        candidates.uniq.each do |c|
          if critical_path?(c)
            log_audit("blocked_write", path: path.to_s, reason: "critical_path")
            raise BlockedWriteError, "Write blocked on critical path: #{path}"
          end
        end

        # Symlink re-check (fail-closed): the lexical candidates above cannot
        # see `foo -> .git/config`. Resolve the deepest EXISTING ancestor and
        # re-check; a missing tail is reattached lexically so ordinary
        # new-file writes resolve to their lexical equivalent. A nil here
        # means containment is unprovable (symlink loop / permission wall).
        resolved = Rubik::Platform.resolved_path(path.to_s, strict: true)
        if resolved.nil?
          log_audit("blocked_write", path: path.to_s, reason: "path_resolution_failed")
          raise BlockedWriteError, "Write blocked: path could not be safely resolved: #{path}"
        end
        if critical_path?(resolved)
          log_audit("blocked_write", path: path.to_s, reason: "critical_path_symlink", resolved: resolved)
          raise BlockedWriteError, "Write blocked on critical path (symlink-resolved): #{path} -> #{resolved}"
        end
        true
      end

      def verify_root_safety!(path)
        return true if path.nil? || path.to_s.strip.empty?

        expanded = File.expand_path(path.to_s)
        normalized = Rubik::Platform.normalize_path(expanded)
        dangerous_roots = Rubik::Platform.dangerous_system_roots

        if dangerous_roots.include?(normalized) ||
           Rubik::Platform.drive_root?(expanded) ||
           Rubik::Platform.path_equal?(expanded, Rubik::Platform.home_dir)
          log_audit("blocked_root_addition", path: expanded, reason: "dangerous_system_root")
          raise BlockedWriteError, "Adding dangerous system root as workspace is blocked: #{path} (#{expanded})"
        end
        true
      end

      def critical_path?(path)
        norm_path = path.to_s.tr("\\", "/").gsub(%r{^\./}, "")
        @critical_patterns.any? do |pattern|
          File.fnmatch?(pattern, norm_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?("**/#{pattern}", norm_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end

      # allow_unknown: the ONLY sanctioned true is the synthesis pre-check —
      # Ruby source ("->(args) { … }") legitimately classifies UNKNOWN through
      # the shell classifier, and synthesis carries its own deny layers
      # (DANGEROUS_SYNTHESIS_PATTERNS + AST walk). Shell-gate callers must keep
      # the default: an UNKNOWN verdict means an unvetted binary, and a binary
      # the database cannot classify is exactly the one that must not run
      # without operator approval.
      def verify_command_safety!(cmd, shell: nil, allow_unknown: false)
        cmd_str = cmd.to_s
        begin
          ast = Rubik::Security::Classifier.classify(cmd_str, shell: shell)
          if ast.classification == :dangerous
            # Safe-probe exemption (highest-priority friction fix): run the
            # catastrophic fallback regex first — it never loosens.
            # Strictly single, isolated command without inner commands or chains.
            single_cmd = ast.respond_to?(:commands) && ast.commands.to_a.size == 1 &&
                         ast.respond_to?(:parse_warnings) && ast.parse_warnings.to_a.empty? &&
                         (!ast.commands.first.respond_to?(:inner_commands) || ast.commands.first.inner_commands.nil? || ast.commands.first.inner_commands.empty?)
            if single_cmd && safe_probe?(cmd_str)
              verify_command_fallback_regex!(cmd_str)
              log_audit("safe_probe", command: cmd_str, reason: "safe_probe_exemption")
              return true
            end
            walk_reason = dangerous_reason(ast.commands)
            # Expression-level elevation marks no single command dangerous —
            # the per-command walk bottoms out at its sentinel while the
            # composed evidence travels on the ExpressionResult itself.
            expression_reason = walk_reason == "dangerous_ast" ? expression_level_reason(ast) : nil
            reason = expression_reason || walk_reason
            # Operator allowlist gate (fail-closed default): the entry must
            # cover EVERY dangerous segment recursively; catastrophic fallback
            # regex still runs afterwards — allowlisting never bypasses it.
            # A bug in the gate itself must fail closed, not fall through to
            # the regex-only downgrade below.
            allowlisted = begin
              command_allowlisted?(ast, cmd_str: cmd_str)
            rescue StandardError => e
              warn "[Guard] allowlist evaluation failed, failing closed: #{e.class}: #{e.message}"
              false
            end
            if allowlisted
              log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist")
              verify_command_fallback_regex!(cmd_str)
              return true
            end
            # Enrichment must never be able to un-block: a bug in the report
            # walk downgrades to nil here, the raise below still fires.
            report = begin
              dangerous_segment_report(ast.commands)
            rescue StandardError => e
              warn "[Guard] segment report failed: #{e.class}: #{e.message}"
              nil
            end
            log_audit("blocked_command", command: cmd_str, reason: reason,
                                         dangerous_segments: segment_count(report))
            # probe_shape? (not safe_probe?): probes only reach this raise when
            # the exemption is disabled, so safe_probe? would be constantly
            # false and the variant-(a) guidance dead code.
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

          # UNKNOWN is fail-closed, not pass-through: the matcher rates every
          # database-less binary unknown/high, so letting it fall through to
          # the catastrophic-only regex would run `socat`/`nmap`/any unlisted
          # tool with zero approval while the tool copy advertises fail-closed.
          # Allowlist rescue unchanged (every top-level segment must match).
          # No safe-probe exemption: an unknown binary's --version still
          # executes an unvetted binary — the allowlist is the valve.
          if ast.classification == :unknown && !allow_unknown
            # Same fail-closed discipline as the dangerous branch: gate
            # trouble must never convert this block into a pass.
            allowlisted = begin
              command_allowlisted?(ast, cmd_str: cmd_str)
            rescue StandardError => e
              warn "[Guard] allowlist evaluation failed, failing closed: #{e.class}: #{e.message}"
              false
            end
            if allowlisted
              log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist")
              verify_command_fallback_regex!(cmd_str)
              return true
            end
            log_audit("blocked_command", command: cmd_str, reason: "unknown_command")
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

          # Ambiguous parse (tree-sitter syntax errors) is a classification
          # failure, not a pass: the walk cannot vouch for the whole
          # expression, so a safe-looking partial verdict must not fall
          # through to the catastrophic-only regex gate. The allowlist stays
          # the valve because a real AST exists — every segment is checked
          # against the operator entries.
          if !allow_unknown && ast.parse_warnings.to_a.any?
            allowlisted = begin
              command_allowlisted?(ast, cmd_str: cmd_str)
            rescue StandardError => e
              warn "[Guard] allowlist evaluation failed, failing closed: #{e.class}: #{e.message}"
              false
            end
            if allowlisted
              log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist")
              verify_command_fallback_regex!(cmd_str)
              return true
            end
            log_audit("blocked_command", command: cmd_str, reason: "parse_ambiguous",
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

          return true if [:readonly, :local_effects, :external_effects].include?(ast.classification) && ast.parse_warnings.empty?
        rescue BlockedWriteError
          raise
        rescue StandardError => e
          # Unconditional warn + audit trail: a classifier crash is a
          # security-observable downgrade nobody should need RUBIK_DEBUG to
          # notice. The shell gate fails closed — an exception must never
          # mint execution permission; the operator allowlist is the one
          # sanctioned valve. The synthesis seam (allow_unknown) keeps
          # flowing into its own deny layers (DANGEROUS_SYNTHESIS_PATTERNS
          # + RubyVM walk), which run after this gate.
          if allow_unknown
            warn "[WARN] AST classification error on non-shell input, continuing to synthesis deny layers: #{e.message}"
            log_audit("classifier_error", command: cmd_str, reason: "#{e.class}: #{e.message}",
                                          decision: "synthesis_layers")
          else
            warn "[WARN] AST classification error, failing closed: #{e.class}: #{e.message}"
            block_on_classifier_failure!(cmd_str, e)
          end
        end

        verify_command_fallback_regex!(cmd_str)
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

      # Structured report for wrapper/multi-segment blocked-command guidance:
      # every innermost dangerous segment with its trigger, the sibling
      # commands that passed, a one-line wrapper preview, and the allowlist
      # entries that would actually open the gate. Plain data only —
      # BlockedWriteError must stay loadable without the classifier stack.
      # nil when no single command is dangerous (expression-level elevations
      # keep the scalar rule_name guidance path).
      def dangerous_segment_report(commands)
        segments = []
        safe = []
        safe_top_argv = []
        wrappers = []
        collect_dangerous_units(commands, 0, segments, safe, safe_top_argv, wrappers)
        return nil if segments.empty?

        # The gate (command_allowlisted?) matches EVERY top-level command,
        # safe ones included — the entry set must cover them all to be
        # honest: wrapper prefix + top-level dangerous segments + top-level
        # safe units.
        entries = wrappers.map { |w| wrapper_allowlist_entry(w) }
        entries += segments.select { |s| s[:depth].zero? }.map { |s| allowlist_entry_for_argv(s[:argv]) }
        entries += safe_top_argv.map { |argv| allowlist_entry_for_argv(argv) }

        {
          segments: segments,
          safe: safe.uniq,
          wrapper_preview: wrappers.empty? ? nil : wrapper_preview(wrappers.first),
          allowlist_entries: entries.uniq
        }.freeze
      end

      # Depth-first walk over the classified command tree. A dangerous
      # command whose danger comes from dangerous inners contributes those
      # inner leaves instead of itself (bash -c "rm -rf /" reports the inner
      # rm, not the wrapper); a dangerous leaf is a segment; non-dangerous
      # leaves join the passed roll call. Top-level wrappers (dangerous only
      # through their inners) are tracked separately for preview + hint;
      # top-level safe units keep their argv for the gate-honest entry set.
      def collect_dangerous_units(commands, depth, segments, safe, safe_top_argv, wrappers)
        Array(commands).each do |c|
          inners = Array(c.inner_commands)
          before = segments.size
          collect_dangerous_units(inners, depth + 1, segments, safe, safe_top_argv, wrappers)
          added = segments.size - before

          if c.classification == :dangerous
            if added.positive?
              wrappers << c if depth.zero?
            else
              segments << dangerous_segment_data(c, depth)
            end
          elsif inners.empty?
            safe << safe_segment_name(c)
            safe_top_argv << c.argv.dup if depth.zero?
          end
        end
      end

      def dangerous_segment_data(result, depth)
        argv = Array(result.argv)
        {
          display: segment_display(display_tokens(argv, result)),
          argv: argv.dup.freeze,
          rule: result.matched_rule,
          option: result.overriding_option,
          reason: result.classification_reason,
          depth: depth
        }
      end

      # Redirect-bearing segments (delegated inners) render their effects,
      # not just their argv: `echo pwned > /etc/shadow`, not `echo pwned`.
      # Flat operator/target tokens keep segment_display's quoting correct;
      # argv itself stays pure — allowlist entries derive from it.
      def display_tokens(argv, result)
        reds = result.respond_to?(:redirects) ? Array(result.redirects) : []
        reds.empty? ? argv : argv + reds.flat_map { |r| [r.operator, r.target] }
      end

      # Subcommand-aware roll call of the units that passed ("git checkout",
      # not just "git") — matches the operator's mental model of the script.
      def safe_segment_name(result)
        result.command.join(" ")
      end

      # One-line wrapper preview for the guidance first line. The delegated
      # payload (the whole -c script) is the argv token that contains
      # whitespace — elide it so the full script is never re-embedded in the
      # message (the defect this report exists to fix).
      def wrapper_preview(result)
        argv = Array(result.argv)
        tokens = argv.dup
        tokens[-1] = "'...'" if tokens.size > 1 && tokens[-1].to_s.match?(/\s/)
        preview = segment_display(tokens)
        preview.length > WRAPPER_PREVIEW_CAP ? "#{preview[0, WRAPPER_PREVIEW_CAP - 1]}..." : preview
      end

      # Shortest top-level argv prefix that actually satisfies the gate's
      # token-prefix match (command_allowlisted?): the wrapper binary up to
      # and including its delegation flag for flag-value payloads
      # ("bash -c", "bash -e -c"), the bare binary for rest-argv wrappers
      # ("sudo", "xargs"). Deriving it from delegation_source keeps the hint
      # gate-honest for flag permutations a naive first-two-tokens guess
      # would miss.
      def wrapper_allowlist_entry(wrapper)
        argv = Array(wrapper.argv)
        return argv.first.to_s if argv.size <= 1

        first_inner = Array(wrapper.inner_commands).first
        if first_inner&.delegation_mode.to_s == "flag_value_is_expression"
          idx = argv.index(first_inner.delegation_source)
          return argv[0..idx].join(" ") if idx&.positive?
        end
        argv.first.to_s
      end

      # An allowlist entry can only carry whitespace-free tokens:
      # normalize_allowlist splits entries on whitespace, so an argv token
      # containing spaces ("feature x") can never be matched by an entry.
      # Prefix up to (excluding) the first such token.
      def allowlist_entry_for_argv(argv)
        prefix = []
        Array(argv).each do |token|
          break if token.to_s.match?(/\s/)

          prefix << token
        end
        prefix.empty? ? Array(argv).first.to_s : prefix.join(" ")
      end

      # Display-only rendering: collapse newlines, single-quote tokens that
      # contain whitespace, hard-cap length. Shellwords.escape would
      # backslash-quote every token (noise on Windows paths) — quote
      # conditionally instead.
      def segment_display(argv)
        text = argv.map { |t| t.to_s.tr("\r\n", " ") }
                   .map { |t| t.match?(/\s/) ? "'#{t}'" : t }
                   .join(" ")
        text.length > SEGMENT_DISPLAY_CAP ? "#{text[0, SEGMENT_DISPLAY_CAP - 1]}..." : text
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
        allowlisted = begin
          command_allowlisted_raw?(cmd_str)
        rescue StandardError => e
          warn "[Guard] raw allowlist evaluation failed, failing closed: #{e.class}: #{e.message}"
          false
        end
        log_audit("classifier_error", command: cmd_str, reason: "#{error.class}: #{error.message}",
                                      decision: allowlisted ? "operator_allowlist" : "blocked")

        if allowlisted
          log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist_classifier_error")
          return
        end

        verify_command_fallback_regex!(cmd_str)
        log_audit("blocked_command", command: cmd_str, reason: "classifier_error")
        raise BlockedWriteError.new(
          "AST evaluation failed, so the command could not be classified; execution blocked (fail-closed): #{cmd_str}",
          kind: :classifier_error,
          blocked_command: cmd_str,
          rule_name: "classifier_error",
          probe_like: probe_shape?(cmd_str),
          segment_report: nil
        )
      end

      # Token-prefix allowlist check for an input whose AST does not exist
      # (classifier crashed). Only a single simple command qualifies: with
      # shell metacharacters present the string may hold several segments
      # and the gate's "every segment must match" contract cannot be
      # honored — fail closed instead of over-promising the prefix match.
      # Quoting is handled by Shellwords; an unparseable string (unbalanced
      # quote) fails closed.
      def command_allowlisted_raw?(cmd_str)
        return false if @command_allowlist.empty?
        return false if cmd_str.match?(RAW_ALLOWLIST_UNSAFE_PATTERN)

        tokens = nil
        begin
          tokens = Shellwords.split(cmd_str)
        rescue ArgumentError
          return false
        end
        return false if tokens.empty?
        return false if Rubik::Security::Classifier::Matcher::BUILTIN_DANGEROUS_CMDS.include?(tokens[0].to_s)

        @command_allowlist.any? do |entry|
          next false if entry.length > tokens.length

          entry.each_with_index.all? do |token, i|
            i.zero? ? binary_allowlist_match?(tokens[i], token) : tokens[i] == token
          end
        end
      end

      def verify_command_fallback_regex!(cmd_str)
        return true unless DANGEROUS_COMMAND_PATTERNS.any? { |p| cmd_str.match?(p) }

        log_audit("blocked_command", command: cmd_str, reason: "dangerous_pattern")
        raise BlockedWriteError.new(
          "Dangerous command execution blocked: #{cmd_str}",
          kind: :dangerous_pattern,
          blocked_command: cmd_str,
          rule_name: "dangerous_pattern"
        )
      end

      # ── Synthesis capability table (Candidate 07) ───────────────────────
      # The ONE declaration point for everything the synthesis AST walk
      # denies (docs/explanation/architecture.md §2 "single declaration point" doctrine; §8.3
      # "the seam is enforced where it is declared"). Each row is a capability
      # a synthesized tool must never exercise; layer fields say WHERE the
      # denial bites:
      #   nodes      — RubyVM node types refused on sight
      #   calls      — call names refused on ANY call shape (:fcall/:vcall
      #                AND :call/:qcall/:attrasgn)
      #   bare_calls — names refused on :fcall/:vcall only; receiver forms
      #                stay legal (ctx.require is the coeffect accessor)
      #   consts     — constants refused as call RECEIVERS only
      #   any_const  — constants refused on ANY :const/:colon3 reference,
      #                anti `X = TCPSocket; X.new` aliasing
      # The FORBIDDEN_SYNTHESIS_* constants below are derived projections of
      # this table, kept under their historical names for the walk's call
      # sites; test_synthesis_capability_coverage.rb locks table <-> constant
      # <-> behavior equivalence so the derivation cannot drift. Note: the
      # :block node (grouped expressions) intentionally has NO row —
      # `(a || b).to_i`-style expressions must stay allowed.
      SynthesisCapability = Struct.new(:name, :reason, :nodes, :calls,
                                       :bare_calls, :consts, :any_const,
                                       keyword_init: true)

      SYNTHESIS_CAPABILITIES = [
        SynthesisCapability.new(
          name: :shell_execution,
          reason: "backtick/%x shell escapes execute outside every Ruby-level guard",
          nodes: [:xstr, :dxstr]
        ),
        SynthesisCapability.new(
          name: :code_definition,
          reason: "method/class definitions mutate the eval target; synthesized payloads are single lambdas",
          nodes: [:defn, :defs, :class, :sclass]
        ),
        SynthesisCapability.new(
          name: :method_table_mutation,
          reason: "alias/undef rewrite the method table behind the guard",
          nodes: [:alias, :undef]
        ),
        SynthesisCapability.new(
          name: :global_state,
          reason: "global variables are process-wide ambient state the host context cannot revert",
          nodes: [:gvar, :gasgn]
        ),
        SynthesisCapability.new(
          name: :dynamic_execution,
          reason: "string eval and Binding turn data into code outside the AST walk",
          calls: [:eval, :instance_eval, :class_eval, :module_eval, :binding]
        ),
        SynthesisCapability.new(
          name: :process_control,
          reason: "subprocess spawn and process lifecycle control escape the sandbox and audit trail; " \
                  "trap/at_exit install process-wide hooks the host cannot revert — Signal.trap can " \
                  "swallow the host REPL's Interrupt/exit handling",
          calls: [:system, :exec, :spawn, :fork, :syscall, :exit!, :trap, :at_exit,
                  :popen, :capture2, :capture2e, :capture3, :popen2, :popen2e,
                  :popen3, :pipeline, :kill, :daemon],
          consts: [:Process, :Thread, :Signal, :Open3]
        ),
        SynthesisCapability.new(
          name: :reflection,
          reason: "send/method-object families bypass static call-name checks (the method(:x).call escape)",
          calls: [:send, :public_send, :__send__,
                  :method, :public_method, :singleton_method]
        ),
        SynthesisCapability.new(
          name: :state_introspection,
          reason: "object internals and object-graph walks fish for live objects and sidestep the AST deny surface (the method(:x).call family at runtime)",
          calls: [:instance_variable_get, :instance_variable_set],
          consts: [:ObjectSpace]
        ),
        SynthesisCapability.new(
          name: :namespace_mutation,
          reason: "const_get/const_set/remove_const read and rewrite constant namespaces at runtime",
          calls: [:const_get, :const_set, :remove_const]
        ),
        SynthesisCapability.new(
          name: :filesystem,
          reason: "raw file/IO handles bypass the OutputView and every guard write check",
          calls: [:open, :read, :write, :binread, :binwrite, :delete, :unlink, :rm_rf],
          consts: [:IO, :File, :Dir, :FileUtils, :STDIN, :STDOUT, :STDERR, :ARGF]
        ),
        SynthesisCapability.new(
          name: :code_loading,
          reason: "require/load execute files outside every guard. :require/:require_relative must NOT live in calls: " \
                  "ctx.require('database') is the canonical coeffect accessor (receiver call) and every synthesized " \
                  "tool depends on it — the bare forms are the escape. Kernel.require/Kernel.load are already caught " \
                  "via :Kernel in runtime_root; obj.load would load arbitrary code or deserialize untrusted state",
          calls: [:load, :autoload],
          bare_calls: [:require, :require_relative, :load, :autoload]
        ),
        SynthesisCapability.new(
          name: :runtime_root,
          reason: "core runtime singletons (Kernel/RubyVM/Class/Module/...) re-open every denied capability",
          consts: [:Kernel, :RubyVM, :Object, :Class, :Module, :BasicObject]
        ),
        SynthesisCapability.new(
          name: :ambient_state,
          reason: "ENV reads expose provider keys / ambient config and mutate process-wide state the host cannot revert",
          consts: [:ENV]
        ),
        SynthesisCapability.new(
          name: :network_serialization,
          reason: "sockets and Marshal have no legitimate synthesized-tool use; receiver-only checks leave " \
                  "`X = TCPSocket; X.new` (:casgn aliasing) wide open, so their mere appearance is a refusal",
          any_const: [:Socket, :IPSocket, :TCPSocket, :TCPServer, :UDPSocket,
                      :UNIXSocket, :UNIXServer, :Net, :Marshal]
        )
      ].map do |cap|
        # Deep-freeze: the ONE declaration point for a security gate must be
        # immutable by construction, not by convention — Struct#freeze alone
        # leaves the member arrays mutable.
        cap.members.each { |member| cap[member].freeze if cap[member].is_a?(Array) }
        cap.freeze
      end.freeze

      # Fold one capability layer into its denial list. Load-time, pure;
      # test_synthesis_capability_coverage.rb pins this helper as the ONLY
      # fold from table to denial constants.
      def self.synthesis_capability_layer(field)
        SYNTHESIS_CAPABILITIES.flat_map { |cap| cap[field].to_a }.freeze
      end

      FORBIDDEN_SYNTHESIS_NODES          = synthesis_capability_layer(:nodes)
      FORBIDDEN_SYNTHESIS_CALLS          = synthesis_capability_layer(:calls)
      FORBIDDEN_SYNTHESIS_BARE_CALLS     = synthesis_capability_layer(:bare_calls)
      FORBIDDEN_SYNTHESIS_CONSTS         = synthesis_capability_layer(:consts)
      FORBIDDEN_SYNTHESIS_NETWORK_CONSTS = synthesis_capability_layer(:any_const)

      # The ONE synthesis gate: every site about to eval synthesized code
      # comes through here (synthesis builtins AND PreflightRunner's
      # spawn-boundary re-check). A guard lacking verify_synthesis_safety!
      # is downgraded to the shell-only gate — the duck-typed fallback is a
      # test-double affordance, but skipping the entire AST deny surface is
      # security-observable, so the downgrade is loud. $stderr.puts, not
      # Kernel#warn: warn is silenced when $VERBOSE is nil (bundler/rake
      # -W0) — same ruling as Log.emit. A failing emit is fail-closed AND
      # honest: refusal with the real cause, never a misattributed
      # "dangerous operations".
      def self.run_synthesis_gate(guard, code)
        if guard.respond_to?(:verify_synthesis_safety!)
          guard.verify_synthesis_safety!(code)
        else
          begin
            $stderr.puts "[Synthesize] guard lacks verify_synthesis_safety!; downgraded to shell-only gate" # rubocop:disable Style/StderrPuts
          rescue StandardError => e
            raise BlockedWriteError,
                  "guard downgrade warn could not be written to stderr (#{e.class}: #{e.message}); refusing to eval"
          end
          guard.verify_command_safety!(code)
        end
      end

      # Reject synthesized Ruby before it is ever eval'd.
      #
      # Defense-in-depth architecture:
      # 1. verify_command_safety! checks shell command patterns.
      # 2. Fast regex pattern matching (DANGEROUS_SYNTHESIS_PATTERNS) intercepts known keywords.
      # 3. RubyVM::AbstractSyntaxTree semantic walk checks normalized node types, method calls,
      #    and receiver constants against explicit deny rules to block AST-level evasion vectors.
      #
      # Raises Rubik::Security::BlockedWriteError with an actionable message.
      def verify_synthesis_safety!(code)
        code_str = code.to_s
        # allow_unknown: synthesized Ruby is not shell — its UNKNOWN verdicts
        # are "not shell-shaped" noise (see verify_command_safety! comment).
        # The shell-classifier layer here still blocks dangerous shapes and
        # still runs the catastrophic regex; synthesis-specific escapes are
        # denied by DANGEROUS_SYNTHESIS_PATTERNS and the AST walk below.
        verify_command_safety!(code_str, allow_unknown: true)

        matched = DANGEROUS_SYNTHESIS_PATTERNS.find { |p| code_str.match?(p) }
        if matched
          log_audit("blocked_synthesis", code: code_str, reason: "dangerous_synthesis_pattern")
          raise BlockedWriteError, "Dangerous synthesis code blocked by security guard: #{matched.inspect}"
        end

        synthesize_safety_walk(code_str)
      end

      def synthesize_safety_walk(code_str)
        ast = begin
          RubyVM::AbstractSyntaxTree.parse(code_str)
        rescue ArgumentError, SyntaxError
          # Code with syntax errors cannot execute; let synthesis eval safely report
          # a SyntaxError to the user rather than misclassifying a syntax typo as a security breach.
          nil
        end

        return true if ast.nil?

        synthesize_safety_check_node(ast)

        true
      end

      # Recursively walk the AST, refusing if any disallowed construct is encountered.
      def synthesize_safety_check_node(node)
        return true unless node.respond_to?(:type)

        type = node.type.to_s.downcase.to_sym
        reject_unsafe(node, "node type :#{type}") if FORBIDDEN_SYNTHESIS_NODES.include?(type)

        case type
        when :const, :colon3
          # :const covers Net::HTTP / Marshal.dump receivers and `X = Socket`
          # RHS values; :colon3 covers top-level scoped `::TCPSocket` — the
          # one-character bypass (children[0] is the name symbol in both).
          name = node.children[0]
          reject_unsafe(node, "reference to forbidden constant :#{name}") if FORBIDDEN_SYNTHESIS_NETWORK_CONSTS.include?(name)
        when :fcall, :vcall
          name = node.children[0]
          reject_unsafe(node, "call to :#{name}") if FORBIDDEN_SYNTHESIS_CALLS.include?(name)
          reject_unsafe(node, "bare call to :#{name}") if FORBIDDEN_SYNTHESIS_BARE_CALLS.include?(name)
        when :call, :qcall, :attrasgn
          recv = node.children[0]
          name = node.children[1]

          reject_unsafe(node, "call to :#{name}") if FORBIDDEN_SYNTHESIS_CALLS.include?(name)

          # Receiver const check must accept BOTH const node shapes: :const
          # (Net::HTTP) and :colon3 (::ENV, ::Thread.new, ::Kernel.require —
          # top-level scoping would otherwise re-open every denylist entry).
          if recv.respond_to?(:type) && [:const, :colon3].include?(recv.type.to_s.downcase.to_sym)
            const_name = recv.children[0]
            reject_unsafe(node, "access to #{const_name}.#{name}") if FORBIDDEN_SYNTHESIS_CONSTS.include?(const_name)
          end
        end

        node.children.compact.each do |c|
          synthesize_safety_check_node(c) if c.respond_to?(:type)
        end
        true
      end

      def reject_unsafe(node, detail = nil)
        kind = node.type.inspect
        reason = detail ? "unsafe_#{detail.to_s.gsub(/\s+/, '_')}" : "unsafe_node_#{kind}"
        log_audit("blocked_synthesis", code: node.children[0].to_s, reason: reason)
        raise BlockedWriteError,
              "Synthesized code was refused by the security guard: #{detail || "a #{kind} node"} is not permitted in synthesized tools."
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
