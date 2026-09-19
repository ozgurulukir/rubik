# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "shellwords"
require_relative "../platform"
require_relative "classifier"

module Rubik
  module Security
    # Carries structured context (command, rule name, probe-ness) so callers
    # can render situation-specific guidance instead of canned boilerplate.
    class BlockedWriteError < StandardError
      attr_accessor :blocked_command, :rule_name, :probe_like
    end

    class Guard
      DEFAULT_CRITICAL_PATTERNS = [
        ".git/**",
        ".env*",
        "secrets.*",
        "*.pem",
        "*.key",
        "id_rsa*"
      ].freeze

      DANGEROUS_COMMAND_PATTERNS = [
        Regexp.new(
          'rm\s+(?:-[a-z0-9-]+\s+)*(?:-[a-z0-9]*r[a-z0-9]*f[a-z0-9]*|-[a-z0-9]*f[a-z0-9]*r[a-z0-9]*|' \
          '(?:(?:-[a-z0-9]*r[a-z0-9]*|--recursive)\s+(?:-[a-z0-9]*f[a-z0-9]*|--force))|' \
          '(?:(?:-[a-z0-9]*f[a-z0-9]*|--force)\s+(?:-[a-z0-9]*r[a-z0-9]*|--recursive)))' \
          '\s+(?:-[a-z0-9-]+\s+)*(?:--\s+)?/(?:\*|\.+(?![a-zA-Z0-9_-])|(?![a-zA-Z0-9_.-]))',
          Regexp::IGNORECASE
        ),
        /(?:curl|wget).*\|\s*(?:bash|sh|zsh|dash|pwsh|python\d?|ruby|perl)/i,
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

      def initialize(custom_patterns: [], command_allowlist: [], allow_safe_probes: true, audit_log_path: File.join(Rubik::Platform.home_dir, ".rubik", "audit.log"))
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

      def set_allowed_commands(entries)
        @command_allowlist = normalize_allowlist(entries)
      end

      def command_allowlisted?(ast, cmd_str: nil)
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
            reason = dangerous_reason(ast.commands)
            # Operator allowlist gate (fail-closed default): the entry must
            # cover EVERY dangerous segment recursively; catastrophic fallback
            # regex still runs afterwards — allowlisting never bypasses it.
            if command_allowlisted?(ast, cmd_str: cmd_str)
              log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist")
              verify_command_fallback_regex!(cmd_str)
              return true
            end
            log_audit("blocked_command", command: cmd_str, reason: reason)
            err = BlockedWriteError.new("Dangerous command execution blocked: #{cmd_str} (reason: #{reason})")
            err.blocked_command = cmd_str
            err.rule_name = dangerous_rule_name(ast.commands) || "dangerous_pattern"
            # probe_shape? (not safe_probe?): probes only reach this raise when
            # the exemption is disabled, so safe_probe? would be constantly
            # false and the variant-(a) guidance dead code.
            err.probe_like = probe_shape?(cmd_str)
            raise err
          end

          return true if [:readonly, :local_effects, :external_effects].include?(ast.classification) && ast.parse_warnings.empty?
        rescue BlockedWriteError
          raise
        rescue StandardError => e
          warn "[WARN] AST classification fallback: #{e.message}" if ENV["RUBIK_DEBUG"]
        end

        verify_command_fallback_regex!(cmd_str)
      end

      def dangerous_reason(commands)
        commands.each do |c|
          next unless c.classification == :dangerous

          inner = dangerous_reason(c.inner_commands) if c.respond_to?(:inner_commands) && c.inner_commands&.any?
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

      def verify_command_fallback_regex!(cmd_str)
        return true unless DANGEROUS_COMMAND_PATTERNS.any? { |p| cmd_str.match?(p) }

        log_audit("blocked_command", command: cmd_str, reason: "dangerous_pattern")
        err = BlockedWriteError.new("Dangerous command execution blocked: #{cmd_str}")
        err.blocked_command = cmd_str
        err.rule_name = "dangerous_pattern"
        raise err
      end

      def verify_synthesis_safety!(code)
        code_str = code.to_s
        verify_command_safety!(code_str)

        matched = DANGEROUS_SYNTHESIS_PATTERNS.find { |p| code_str.match?(p) }
        return true unless matched

        log_audit("blocked_synthesis", code: code_str, reason: "dangerous_synthesis_pattern")
        raise BlockedWriteError, "Dangerous synthesis code blocked by security guard: #{matched.inspect}"
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
        warn "[WARN] Failed to write audit log #{@audit_log_path}: #{e.message}" if ENV["RUBIK_DEBUG"]
      end
    end
  end
end
