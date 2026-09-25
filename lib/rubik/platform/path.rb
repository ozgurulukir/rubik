# frozen_string_literal: true

module Rubik
  module Platform
    # Path resolution, normalization, URI conversion and path safety checks.
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Path
      def self.included(base)
        base.extend self
      end

      # Pure-Ruby cross-platform binary resolver
      def which(cmd)
        return nil if cmd.nil? || cmd.to_s.strip.empty?

        cmd_str = cmd.to_s.strip.split.first
        return nil if cmd_str.nil? || cmd_str.empty?

        # Windows shell builtins (e.g. echo, dir, cls)
        return cmd_str if windows? && Rubik::Platform::WINDOWS_SHELL_BUILTINS.include?(cmd_str.downcase)

        # If full/relative path is provided
        if cmd_str.include?("/") || (windows? && cmd_str.include?("\\"))
          return File.expand_path(cmd_str).gsub("\\", "/") if File.file?(cmd_str) && executable_file?(cmd_str)

          if windows?
            pathext.each do |ext|
              candidate = "#{cmd_str}#{ext}"
              return File.expand_path(candidate).gsub("\\", "/") if File.file?(candidate) && executable_file?(candidate)
            end
          end
          return nil
        end

        # Search in PATH
        paths = (ENV["PATH"] || "").split(File::PATH_SEPARATOR)
        exts = if windows?
                 ext = File.extname(cmd_str)
                 ext.empty? ? pathext : ([""] + pathext).uniq
               else
                 [""]
               end

        paths.each do |dir|
          next if dir.empty? || !File.directory?(dir)

          exts.each do |ext|
            target = File.join(dir, "#{cmd_str}#{ext}")
            return File.expand_path(target).gsub("\\", "/") if File.file?(target) && executable_file?(target)
          end
        end
        nil
      end

      def pathext
        (ENV["PATHEXT"] || ".COM;.EXE;.BAT;.CMD;.VBS;.JS;.WS;.MSC;.PS1").split(";").map(&:downcase)
      end

      def executable_file?(path)
        return false unless File.file?(path)

        windows? || File.executable?(path)
      end

      # RFC 8089 Compliant File URI (e.g. file:///C:/path/file vs file:///path/file)
      def to_file_uri(path)
        normalized = normalize_path_raw(path)
        if windows? && normalized =~ %r{^([a-zA-Z]):/(.*)$}
          "file:///#{::Regexp.last_match(1)}:/#{::Regexp.last_match(2)}"
        else
          normalized.start_with?("/") ? "file://#{normalized}" : "file:///#{normalized}"
        end
      end

      def from_file_uri(uri)
        str = uri.to_s.sub(%r{^file://}, "")
        str = CGI.unescape(str)
        if windows?
          # Handles file:///C:/... and file://C:/...
          if str =~ %r{^/?([a-zA-Z]:/.*)$}
            ::Regexp.last_match(1)
          else
            str
          end
        else
          str.start_with?("/") ? str : "/#{str}"
        end
      end

      def normalize_path_raw(path)
        expanded = File.expand_path(path.to_s)
        expanded.gsub("\\", "/")
      end

      # Normalizes separators and casing for comparison
      def normalize_path(path)
        raw = normalize_path_raw(path)
        windows? ? raw.downcase : raw
      end

      def path_equal?(lhs, rhs)
        normalize_path(lhs) == normalize_path(rhs)
      end

      def path_under?(child, parent)
        n_child = normalize_path(child)
        n_parent = normalize_path(parent)
        return true if n_child == n_parent

        clean_parent = n_parent.chomp("/")
        clean_child = n_child.chomp("/")
        return true if clean_child == clean_parent

        n_child.start_with?("#{clean_parent}/")
      end

      # Realpath for security-boundary containment decisions ONLY (stored
      # buffer keys and every other comparison stay lexical). The deepest
      # EXISTING ancestor is resolved and the not-yet-existing tail is
      # re-attached lexically — a missing component cannot be a symlink,
      # and File.expand_path has already collapsed ".." lexically.
      # If strict: true (used in containment checks), IO resolution failure
      # returns nil so resolved_path_under? fails closed (unprovable containment).
      # If strict: false, falls back to lexical path for display/diagnostics.
      def resolved_path(path, strict: false)
        expanded = File.expand_path(path.to_s)
        begin
          return File.realpath(expanded)
        rescue Errno::ENOENT, Errno::ENOTDIR
          begin
            dir, tail = expanded, []
            until dir == File.dirname(dir) || File.exist?(dir)
              tail.unshift(File.basename(dir))
              dir = File.dirname(dir)
            end
            base = File.realpath(dir)
            return tail.empty? ? base : File.join(base, *tail)
          rescue SystemCallError => e
            debug_warn "resolved_path: ancestor walk failed for #{expanded}: #{e.message}"
            return nil if strict

            expanded
          end
        rescue SystemCallError => e
          debug_warn "resolved_path: resolution failed for #{expanded}: #{e.message}"
          return nil if strict

          expanded
        end
      end

      # Best-effort variant for read-only / display / diagnostics (never fails closed)
      def resolved_path_best_effort(path)
        resolved_path(path, strict: false)
      end

      # Drop-in twin of path_under? that resolves symlinks/junctions on BOTH
      # sides before the prefix comparison. Security boundaries (Buffer
      # containment, Sandbox chdir checks) must use this variant.
      # Fail-closed invariant (W1): IO/permission failure returns false (containment unprovable).
      def resolved_path_under?(child, parent)
        r_child = resolved_path(child, strict: true)
        return false if r_child.nil?

        r_parent = resolved_path(parent, strict: true)
        return false if r_parent.nil?

        path_under?(r_child, r_parent)
      end

      def dangerous_system_roots
        roots = ["/", "/root", "/home", "/etc", "/usr", "/var", "/bin", "/sbin", "/lib", "/lib64", "/opt", "/boot", "/dev", "/proc", "/sys"]
        if windows?
          # Add expanded Unix root equivalents on current drive (e.g. C:/etc, C:/usr)
          roots += roots.map { |r| File.expand_path(r) }
          roots += ["c:/", "c:/windows", "c:/windows/system32", "c:/program files", "c:/program files (x86)", "c:/users", "c:/programdata"]
          roots << ENV["SystemRoot"] if ENV["SystemRoot"]
          roots << ENV["ProgramFiles"] if ENV["ProgramFiles"]
          roots << ENV["ProgramFiles(x86)"] if ENV["ProgramFiles(x86)"]
          roots << ENV["CommonProgramFiles"] if ENV["CommonProgramFiles"]
          roots << ENV["USERPROFILE"] if ENV["USERPROFILE"]
          roots << "#{ENV['SystemDrive']}/" if ENV["SystemDrive"]
          roots << ENV["SystemDrive"] if ENV["SystemDrive"]
        end
        roots << home_dir
        roots.compact.map { |r| normalize_path(r) }.uniq
      end

      def drive_root?(path)
        return false unless windows?

        normalize_path(path) =~ %r{^[a-z]:/?$}
      end
    end
  end
end
