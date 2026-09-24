# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "shellwords"
require_relative "../platform"
require_relative "classifier"
require_relative "errors"

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

      MASK_PATTERNS = [
        /sk-[a-zA-Z0-9_-]{20,}/,
        # Recorder Fix 2/5/6 parity: Anthropic (sk-ant-), GitHub fine-grained
        # (github_pat_), and Google (AIzaSy...) keys must be masked in the
        # Guard/audit surface too, not only in persisted session recordings.
        /sk-ant-[a-zA-Z0-9_-]{20,}/,
        /AKIA[0-9A-Z]{16}/,
        /ghp_[a-zA-Z0-9]{36}/,
        /github_pat_[a-zA-Z0-9_]{22,}/,
        /AIzaSy[a-zA-Z0-9_-]{33}/,
        # \b + 20-char floor: real bearer credentials (JWTs, opaque tokens) are
        # long; the loose form masked prose like "the bearer of bad news".
        /\bbearer\s+[a-zA-Z0-9_\-.]{20,}/i
      ].freeze

      # Salt version/help probe'ları (Plan: safe-probe muafiyeti): a command
      # whose ONLY arguments are these flags is read-only by construction.
      SAFE_PROBE_FLAGS = ["--version", "-v", "--help", "-h"].freeze

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
        rescue StandardError
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

      def command_matches_allowlist?(result)
        # Missing argv (e.g. empty invocation) can never be allowlisted.
        argv = result.respond_to?(:argv) ? result.argv : nil
        return false if argv.nil? || argv.empty?

        # Dangerous shell builtins (`source`, `.`) are never rescuable by
        # allowlist: they execute arbitrary file content by design.
        binary = argv[0].to_s
        return false if Rubik::Security::Classifier::Matcher::BUILTIN_DANGEROUS_CMDS.include?(binary)

        @command_allowlist.any? do |entry|
          next false if entry.length > argv.length

          entry.each_with_index.all? do |token, i|
            arg = argv[i]
            arg == token || (i.zero? && Rubik::Platform.windows? && File.basename(arg, ".*").casecmp?(File.basename(token, ".*")))
          end
        end
      end

      public

      def verify_path_write!(path)
        rel_path = path.to_s.gsub(%r{^\./}, "")
        if critical_path?(rel_path)
          log_audit("blocked_write", path: rel_path, reason: "critical_path")
          raise BlockedWriteError, "Write blocked on critical path: #{rel_path}"
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

      def verify_command_safety!(cmd, shell: nil)
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
            if command_allowlisted?(ast, cmd_str: cmd_str)
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

          return true if [:readonly, :local_effects, :external_effects].include?(ast.classification) && ast.parse_warnings.empty?
        rescue BlockedWriteError
          raise
        rescue StandardError => e
          # Unconditional warn + audit trail: a classifier crash downgrades
          # this verification to the narrow fallback regex, silently skipping
          # allowlist/probe logic — a security-observable downgrade nobody
          # should need RUBIK_DEBUG to notice.
          warn "[WARN] AST classification error, falling back to regex gate: #{e.message}"
          log_audit("classifier_error", command: cmd_str, reason: "#{e.class}: #{e.message}")
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

      # Forbidden node types: code definitions, class reopening, global vars, and command execution.
      # Note: :block represents grouped expressions / begin blocks in RubyVM AST, which must remain
      # allowed for expressions like `(a || b).to_i`.
      FORBIDDEN_SYNTHESIS_NODES = [
        :xstr, :dxstr, :defn, :defs, :class, :sclass, :alias, :undef, :gvar, :gasgn
      ].freeze

      # Forbidden method invocations (bare calls, receiver calls, reflection, evasion vectors).
      FORBIDDEN_SYNTHESIS_CALLS = [
        :eval, :instance_eval, :class_eval, :module_eval, :binding,
        :system, :exec, :spawn, :fork, :syscall, :exit!,
        :popen, :capture2, :capture2e, :capture3, :popen2, :popen2e, :popen3, :pipeline,
        :kill, :daemon,
        :send, :public_send, :__send__,
        :method, :public_method, :singleton_method,
        :instance_variable_get, :instance_variable_set,
        :const_get, :const_set, :remove_const,
        :open, :read, :write, :binread, :binwrite, :delete, :unlink, :rm_rf
      ].freeze

      # Forbidden receiver constants (dangerous subsystems, process, thread, and filesystem handles).
      FORBIDDEN_SYNTHESIS_CONSTS = [
        :IO, :File, :Dir, :FileUtils, :Process, :Kernel, :Open3,
        :RubyVM, :Object, :Class, :Module, :BasicObject, :Thread,
        # secrets-env: ENV reads expose provider keys / ambient config and
        # mutate process-wide state the host cannot revert.
        :ENV,
        # introspection: object-graph walks can fish for live objects and
        # sidestep the AST deny surface (the method(:x).call family at runtime).
        :ObjectSpace,
        # raw-IO handles bypass the OutputView and every guard write check.
        :STDIN, :STDOUT, :STDERR, :ARGF,
        # Signal.trap can swallow the host REPL's Interrupt/exit handling.
        :Signal
      ].freeze

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
        verify_command_safety!(code_str)

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
        when :fcall, :vcall
          name = node.children[0]
          reject_unsafe(node, "call to :#{name}") if FORBIDDEN_SYNTHESIS_CALLS.include?(name)
        when :call, :qcall, :attrasgn
          recv = node.children[0]
          name = node.children[1]

          reject_unsafe(node, "call to :#{name}") if FORBIDDEN_SYNTHESIS_CALLS.include?(name)

          if recv.respond_to?(:type) && recv.type.to_s.downcase.to_sym == :const
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
        return text unless text.is_a?(String)

        result = text.dup
        MASK_PATTERNS.each do |pattern|
          result.gsub!(pattern, "***MASKED***")
        end
        result
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
