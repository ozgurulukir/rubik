# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "fileutils"
require "cgi"

module Rubik
  module Platform
    WINDOWS_SHELL_BUILTINS = %w[
      echo dir cd cls set type copy move del md rd exit rem ver vol
    ].freeze

    class << self
      def host_os
        RbConfig::CONFIG["host_os"] || ""
      end

      def ruby_platform
        RUBY_PLATFORM
      end

      def os_family
        if windows?
          :windows
        elsif macos?
          :macos
        elsif linux?
          :linux
        else
          :unknown
        end
      end

      def windows?
        Gem.win_platform? || (host_os =~ /mswin|mingw|cygwin|bccwin|wince/i) != nil
      end

      def macos?
        (host_os =~ /darwin/i) != nil
      end

      def linux?
        !windows? && !macos?
      end

      def unix?
        !windows?
      end

      def dev_null
        windows? ? "NUL" : "/dev/null"
      end

      def home_dir
        Dir.home rescue (ENV["USERPROFILE"] || (ENV["HOMEDRIVE"] && ENV["HOMEPATH"] && "#{ENV["HOMEDRIVE"]}#{ENV["HOMEPATH"]}") || ENV["HOME"] || ".")
      end

      def tmp_dir
        Dir.tmpdir rescue (ENV["TEMP"] || ENV["TMP"] || "/tmp")
      end

      # Pure-Ruby cross-platform binary resolver
      def which(cmd)
        return nil if cmd.nil? || cmd.to_s.strip.empty?
        cmd_str = cmd.to_s.strip.split.first
        return nil if cmd_str.nil? || cmd_str.empty?

        # Windows shell builtins (e.g. echo, dir, cls)
        if windows? && WINDOWS_SHELL_BUILTINS.include?(cmd_str.downcase)
          return cmd_str
        end

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
        windows? ? true : File.executable?(path)
      end

      # RFC 8089 Compliant File URI (e.g. file:///C:/path/file vs file:///path/file)
      def to_file_uri(path)
        normalized = normalize_path_raw(path)
        if windows? && normalized =~ /^([a-zA-Z]):\/(.*)$/
          "file:///#{$1}:/#{$2}"
        else
          normalized.start_with?("/") ? "file://#{normalized}" : "file:///#{normalized}"
        end
      end

      def from_file_uri(uri)
        str = uri.to_s.sub(/^file:\/\//, "")
        str = CGI.unescape(str)
        if windows?
          # Handles file:///C:/... and file://C:/...
          if str =~ /^\/([a-zA-Z]:\/.*)$/
            $1
          elsif str =~ /^([a-zA-Z]:\/.*)$/
            $1
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

      def path_equal?(p1, p2)
        normalize_path(p1) == normalize_path(p2)
      end

      def path_under?(child, parent)
        n_child = normalize_path(child)
        n_parent = normalize_path(parent)
        n_child == n_parent || n_child.start_with?("#{n_parent}/")
      end

      def dangerous_system_roots
        roots = %w[/ /root /home /etc /usr /var /bin /sbin /lib /lib64 /opt /boot /dev /proc /sys]
        if windows?
          # Add expanded Unix root equivalents on current drive (e.g. C:/etc, C:/usr)
          roots += roots.map { |r| File.expand_path(r) }
          roots += %w[c:/ c:/windows c:/windows/system32 c:/program\ files c:/program\ files\ (x86) c:/users c:/programdata]
          roots << ENV["SystemRoot"] if ENV["SystemRoot"]
          roots << ENV["ProgramFiles"] if ENV["ProgramFiles"]
          roots << ENV["ProgramFiles(x86)"] if ENV["ProgramFiles(x86)"]
          roots << ENV["CommonProgramFiles"] if ENV["CommonProgramFiles"]
          roots << ENV["USERPROFILE"] if ENV["USERPROFILE"]
          roots << "#{ENV["SystemDrive"]}/" if ENV["SystemDrive"]
          roots << ENV["SystemDrive"] if ENV["SystemDrive"]
        end
        roots << home_dir
        roots.compact.map { |r| normalize_path(r) }.uniq
      end

      def drive_root?(path)
        return false unless windows?
        normalize_path(path) =~ /^[a-z]:\/?$/
      end

      def kill_tree(pid)
        return unless pid && pid > 0
        if windows?
          system("taskkill /F /T /PID #{pid} > NUL 2>&1") rescue nil
        else
          Process.kill("TERM", pid) rescue nil
          Process.kill("KILL", pid) rescue nil
        end
      end

      def atomic_write(target_path, content)
        dir = File.dirname(target_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        tmp_file = "#{target_path}.tmp.#{Process.pid}.#{rand(100000)}"
        File.write(tmp_file, content)

        if File.exist?(target_path)
          File.unlink(target_path) rescue nil
        end
        File.rename(tmp_file, target_path)
      rescue StandardError
        File.write(target_path, content)
      ensure
        File.unlink(tmp_file) if File.exist?(tmp_file) rescue nil
      end

      def normalize_newlines(content)
        content.to_s.gsub("\r\n", "\n")
      end
    end
  end
end
