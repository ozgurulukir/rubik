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

      # Commands whose positional arguments name write targets (issue #671).
      WRITE_COMMANDS = [
        "cp", "mv", "tee", "touch", "ln", "install", "rm", "mkdir", "rsync", "dd", "chmod", "chown", "git"
      ].freeze

      # Options whose VALUES are write targets. Positionals cover the common
      # case; these cover `-o`, `-t`, `-C`, `--target-directory`, etc.
      WRITE_TARGET_OPTIONS = {
        "cp" => ["-t", "--target-directory"],
        "mv" => ["-t", "--target-directory"],
        "tar" => ["-C", "--directory", "-f", "--file"],
        "curl" => ["-o", "--output"],
        "wget" => ["-O", "--output-document"],
        "git" => ["--separate-git-dir"]
      }.freeze

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

      # Segment-wise matching: File.fnmatch?'s `**` does not cross `/`
      # without FNM_PATHNAME's cooperation at the tail, so `.git/**` only
      # ever protected one level. `**` here means zero or more whole path
      # segments, and every pattern matches at any depth (the old `**/`
      # prefix behaviour). A de-globbed candidate closes `.en?v`-style
      # metacharacter evasions without trying to predict shell expansion.
      def critical_path?(path)
        norm = path.to_s.tr("\\", "/").gsub(%r{\A\./}, "").sub(%r{/+\z}, "").strip
        return false if norm.empty?

        [norm, norm.gsub(/[*?\[\]\\]/, "")].uniq.any? do |candidate|
          segments = candidate.split("/").reject(&:empty?)
          @critical_patterns.any? { |pattern| pattern_matches?(pattern.to_s.tr("\\", "/"), segments) }
        end
      end

      def pattern_matches?(pattern, segments)
        pattern_segments = pattern.split("/").reject(&:empty?)
        return false if pattern_segments.empty? || segments.empty?

        (0...segments.size).any? { |start| match_segments?(pattern_segments, segments[start..]) }
      end

      def match_segments?(pattern_segments, path_segments)
        return path_segments.empty? if pattern_segments.empty?

        head = pattern_segments.first
        tail = pattern_segments[1..]
        if head == "**"
          return match_segments?(tail, path_segments) ||
                 (!path_segments.empty? && match_segments?(pattern_segments, path_segments[1..]))
        end
        return false if path_segments.empty?
        return false unless File.fnmatch?(head, path_segments.first, File::FNM_DOTMATCH)

        match_segments?(tail, path_segments[1..])
      end

      # Values of write-target options in either `--opt=value`, `--opt value`
      # or joined short `-ovalue` form.
      def option_write_targets(cmd_name, argv)
        names = WRITE_TARGET_OPTIONS[cmd_name] || []
        return [] if names.empty?

        targets = []
        argv.each_with_index do |token, i|
          names.each do |name|
            if token == name
              value = argv[i + 1]
              targets << value if value && !value.start_with?("-")
            elsif token.start_with?("#{name}=")
              targets << token.split("=", 2).last
            elsif !name.start_with?("--") && token.start_with?(name) && token.length > name.length
              targets << token[name.length..]
            end
          end
        end
        targets
      end

      def check_critical_path_writes!(ast, cmd_str)
        ast_commands = ast.respond_to?(:commands) ? ast.commands.to_a : []
        write_targets = ast_commands.flat_map do |c|
          targets = Array(c.respond_to?(:write_paths) ? c.write_paths : nil)
          cmd_name = c.respond_to?(:command) ? c.command.to_a.first.to_s : ""
          if WRITE_COMMANDS.include?(cmd_name) || WRITE_TARGET_OPTIONS.key?(cmd_name)
            targets.concat(c.positionals.to_a) if WRITE_COMMANDS.include?(cmd_name) && c.respond_to?(:positionals)
            targets.concat(Array(c.directories)) if c.respond_to?(:directories)
            argv = c.respond_to?(:argv) ? c.argv.to_a : []
            targets.concat(option_write_targets(cmd_name, argv))
          end
          targets
        end
        write_targets = write_targets.compact.reject { |t| t.to_s.empty? }

        write_targets.concat(ast.write_paths.to_a) if ast.respond_to?(:write_paths)

        write_targets.uniq.each do |wp|
          if critical_path?(wp)
            @audit.log_audit("blocked_command", command: cmd_str, reason: "critical_path_write", path: wp)
            display = Rubik::Security.display_command(cmd_str)
            raise BlockedWriteError.new(
              "Command write to critical path blocked: #{wp} in `#{display}`",
              kind: :critical_path_write,
              blocked_command: display,
              path: wp
            )
          end

          # Symlink re-check (fail-closed, issue #590): the lexical test above
          # cannot see `evil -> .git/config`, so `echo x > evil` would sail
          # through while naming nothing critical. Resolve each write target
          # exactly like verify_path_write! does and re-check the resolution;
          # a nil resolution (symlink loop / permission wall) fails closed.
          resolved = Rubik::Platform.resolved_path(wp, strict: true)
          if resolved.nil?
            @audit.log_audit("blocked_command", command: cmd_str, reason: "path_resolution_failed", path: wp)
            display = Rubik::Security.display_command(cmd_str)
            raise BlockedWriteError.new(
              "Command write blocked: path could not be safely resolved: #{wp} in `#{display}`",
              kind: :critical_path_write,
              blocked_command: display,
              path: wp
            )
          end
          next unless critical_path?(resolved)

          @audit.log_audit("blocked_command", command: cmd_str, reason: "critical_path_write_symlink", path: wp, resolved: resolved)
          display = Rubik::Security.display_command(cmd_str)
          raise BlockedWriteError.new(
            "Command write to critical path blocked (symlink-resolved): #{wp} -> #{resolved} in `#{display}`",
            kind: :critical_path_write,
            blocked_command: display,
            path: wp
          )
        end
      end
    end
  end
end
