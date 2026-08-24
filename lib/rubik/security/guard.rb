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
        /rm\s+-rf\s+\//,
        /curl.*\|\s*sh/,
        /wget.*\|\s*sh/,
        /:\(\)\{\s*:\|\:&\s*\};:/, # fork bomb
        /del\s+.*\/s.*[a-z]:\\/i,
        /erase\s+.*\/s.*[a-z]:\\/i,
        /rmdir\s+.*\/s.*[a-z]:\\/i,
        /rd\s+.*\/s.*[a-z]:\\/i,
        /format\s+[a-z]:/i,
        /Remove-Item\s+.*-Recurse.*[a-z]:\\/i,
        /%0\|%0/
      ].freeze

      DANGEROUS_SYSTEM_ROOTS = %w[
        /
        /root
        /home
        /etc
        /usr
        /var
        /bin
        /sbin
        /lib
        /lib64
        /opt
        /boot
        /dev
        /proc
        /sys
      ].freeze

      MASK_PATTERNS = [
        /sk-[a-zA-Z0-9_-]{20,}/,
        /AKIA[0-9A-Z]{16}/,
        /ghp_[a-zA-Z0-9]{36}/,
        /bearer\s+[a-zA-Z0-9_\-\.]+/i
      ].freeze

      attr_reader :audit_log_path

      def initialize(custom_patterns: [], audit_log_path: File.join(Rubik::Platform.home_dir, ".rubik", "audit.log"))
        @critical_patterns = (DEFAULT_CRITICAL_PATTERNS + custom_patterns).uniq
        @audit_log_path = audit_log_path
        FileUtils.mkdir_p(File.dirname(@audit_log_path))
      end

      def verify_path_write!(path)
        rel_path = path.to_s.gsub(/^\.\//, "")
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
        @critical_patterns.any? do |pattern|
          File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?("**/#{pattern}", path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
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

      def mask_text(text)
        return text unless text.is_a?(String)

        result = text.dup
        MASK_PATTERNS.each do |pattern|
          result.gsub!(pattern, "***MASKED***")
        end
        result
      end

      def log_audit(action, details = {})
        masked_details = details.transform_values { |v| mask_text(v.to_s) }

        entry = {
          ts: Time.now.iso8601,
          action: action,
          details: masked_details
        }

        File.open(@audit_log_path, "a") do |f|
          f.puts(JSON.dump(entry))
        end
      end
    end
  end
end
