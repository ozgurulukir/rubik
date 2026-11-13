# frozen_string_literal: true

require_relative "../platform"
require_relative "errors"

module Rubik
  module Security
    # Critical-path write policy, split out of Guard (#403): the default
    # critical patterns, the path-write verifier, the workspace-root
    # verifier, and the command write-target walk. Receives the shared
    # AuditLog instance — every block decision is audit-logged there.
    class PathPolicy
      DEFAULT_CRITICAL_PATTERNS = [
        ".git/**",
        ".rubik/**",
        "**/.rubik/**",
        ".env*",
        "secrets.*",
        "*.pem",
        "*.key",
        "id_rsa*"
      ].freeze

      def initialize(audit:, custom_patterns: [])
        @critical_patterns = (DEFAULT_CRITICAL_PATTERNS + custom_patterns).uniq
        @audit = audit
      end

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
            @audit.log_audit("blocked_write", path: path.to_s, reason: "critical_path")
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
          @audit.log_audit("blocked_write", path: path.to_s, reason: "path_resolution_failed")
          raise BlockedWriteError, "Write blocked: path could not be safely resolved: #{path}"
        end
        if critical_path?(resolved)
          @audit.log_audit("blocked_write", path: path.to_s, reason: "critical_path_symlink", resolved: resolved)
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
          @audit.log_audit("blocked_root_addition", path: expanded, reason: "dangerous_system_root")
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

      def check_critical_path_writes!(ast, cmd_str)
        ast_commands = ast.respond_to?(:commands) ? ast.commands.to_a : []
        write_targets = ast_commands.flat_map do |c|
          targets = Array(c.respond_to?(:write_paths) ? c.write_paths : nil)
          cmd_name = c.respond_to?(:command) ? c.command.to_a.first.to_s : ""
          targets.concat(c.positionals.to_a) if ["cp", "mv", "tee", "touch", "ln", "install"].include?(cmd_name) && c.respond_to?(:positionals)
          targets
        end.compact.reject(&:empty?)

        write_targets.concat(ast.write_paths.to_a) if ast.respond_to?(:write_paths)

        write_targets.uniq.each do |wp|
          next unless critical_path?(wp)

          @audit.log_audit("blocked_command", command: cmd_str, reason: "critical_path_write", path: wp)
          raise BlockedWriteError.new(
            "Command write to critical path blocked: #{wp} in `#{cmd_str}`",
            kind: :critical_path_write,
            blocked_command: cmd_str,
            path: wp
          )
        end
      end
    end
  end
end
