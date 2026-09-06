# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "../platform"

module Rubik
  module Security
    class BlockedWriteError < StandardError; end

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
        /curl.*\|\s*sh/,
        /wget.*\|\s*sh/,
        /:\(\)\{\s*:\|:&\s*\};:/, # fork bomb
        %r{\bdd\s+.*(?:if=|of=/dev/)}i,
        /\bmkfs(?:\.\w+)?\b/i,
        %r{del\s+.*/s.*[a-z]:\\}i,
        %r{erase\s+.*/s.*[a-z]:\\}i,
        %r{rmdir\s+.*/s.*[a-z]:\\}i,
        %r{rd\s+.*/s.*[a-z]:\\}i,
        /format\s+[a-z]:/i,
        /Remove-Item\s+.*-Recurse.*[a-z]:\\/i,
        /%0\|%0/
      ].freeze

      DANGEROUS_SYNTHESIS_PATTERNS = [
        /\b(?:send|public_send|__send__)\s*[( \s]/,
        /\.(?:send|public_send|__send__)\b/,
        /\beval\s*[( \s]/,
        /\bbinding\s*\.\s*eval\b/i,
        /\b(?:instance_eval|class_eval|module_eval)\b/,
        /\b(?:instance_variable_get|instance_variable_set)\b/,
        /\b(?:const_set|const_get|remove_const)\b/,
        /\bIO\s*\.\s*popen\b/,
        /\bOpen3\s*\.\s*(?:capture2|capture2e|capture3|popen2|popen2e|popen3|pipeline)\b/,
        /\bProcess\s*\.\s*(?:kill|fork|daemon|spawn|exec)\b/,
        /\bKernel\s*\.\s*(?:exec|system|fork|spawn|syscall|exit!)\b/,
        /`[^`]*`/,
        Regexp.new('%x\s*[({\[<|/]', Regexp::IGNORECASE)
      ].freeze

      DANGEROUS_SYSTEM_ROOTS = [
        "/",
        "/root",
        "/home",
        "/etc",
        "/usr",
        "/var",
        "/bin",
        "/sbin",
        "/lib",
        "/lib64",
        "/opt",
        "/boot",
        "/dev",
        "/proc",
        "/sys"
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

      attr_reader :audit_log_path

      def initialize(custom_patterns: [], audit_log_path: File.join(Rubik::Platform.home_dir, ".rubik", "audit.log"))
        @critical_patterns = (DEFAULT_CRITICAL_PATTERNS + custom_patterns).uniq
        @audit_log_path = audit_log_path
      end

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

      def verify_command_safety!(cmd)
        cmd_str = cmd.to_s
        DANGEROUS_COMMAND_PATTERNS.each do |pattern|
          if cmd_str.match?(pattern)
            log_audit("blocked_command", command: cmd_str, reason: "dangerous_pattern")
            raise BlockedWriteError, "Dangerous command execution blocked: #{cmd_str}"
          end
        end
        true
      end

      def verify_synthesis_safety!(code)
        code_str = code.to_s
        verify_command_safety!(code_str)

        DANGEROUS_SYNTHESIS_PATTERNS.each do |pattern|
          if code_str.match?(pattern)
            log_audit("blocked_synthesis", code: code_str, reason: "dangerous_synthesis_pattern")
            raise BlockedWriteError, "Dangerous synthesis code blocked by security guard: #{pattern.inspect}"
          end
        end
        true
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

        masked_details = details.transform_values { |v| mask_text(v.to_s) }

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
