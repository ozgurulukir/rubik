# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "fileutils"
require "cgi"
require "json"

module Rubik
  module Platform
    WINDOWS_SHELL_BUILTINS = [
      "echo", "dir", "cd", "cls", "set", "type", "copy", "move", "del", "md", "rd", "exit", "rem", "ver", "vol"
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
        Gem.win_platform? || !(host_os =~ /mswin|mingw|cygwin|bccwin|wince/i).nil?
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
        File::NULL
      end

      def home_dir
        Dir.home
      rescue
        (ENV["USERPROFILE"] || (ENV.fetch("HOMEDRIVE",
                                          nil) && ENV.fetch("HOMEPATH",
                                                            nil) && "#{ENV.fetch('HOMEDRIVE',
                                                                                 nil)}#{ENV.fetch('HOMEPATH', nil)}") || ENV["HOME"] || ".")
      end

      def tmp_dir
        Dir.tmpdir
      rescue
        (ENV["TEMP"] || ENV["TMP"] || "/tmp")
      end

      # Pure-Ruby cross-platform binary resolver
      def which(cmd)
        return nil if cmd.nil? || cmd.to_s.strip.empty?

        cmd_str = cmd.to_s.strip.split.first
        return nil if cmd_str.nil? || cmd_str.empty?

        # Windows shell builtins (e.g. echo, dir, cls)
        return cmd_str if windows? && WINDOWS_SHELL_BUILTINS.include?(cmd_str.downcase)

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
          if str =~ %r{^/([a-zA-Z]:/.*)$}
            ::Regexp.last_match(1)
          elsif str =~ %r{^([a-zA-Z]:/.*)$}
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

      def path_equal?(p1, p2)
        normalize_path(p1) == normalize_path(p2)
      end

      def path_under?(child, parent)
        n_child = normalize_path(child)
        n_parent = normalize_path(parent)
        n_child == n_parent || n_child.start_with?("#{n_parent}/")
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

      def kill_tree(pid)
        return unless pid && pid.positive?

        if windows?
          begin
            system("taskkill /F /T /PID #{pid} > NUL 2>&1")
          rescue
            nil
          end
        else
          begin
            Process.kill("TERM", pid)
          rescue
            nil
          end
          begin
            Process.kill("KILL", pid)
          rescue
            nil
          end
        end
      end

      def atomic_write(target_path, content)
        dir = File.dirname(target_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        tmp_file = "#{target_path}.tmp.#{Process.pid}.#{rand(100_000)}"
        File.write(tmp_file, content)

        if File.exist?(target_path)
          begin
            File.unlink(target_path)
          rescue
            nil
          end
        end
        File.rename(tmp_file, target_path)
      rescue StandardError
        File.write(target_path, content)
      ensure
        begin
          FileUtils.rm_f(tmp_file)
        rescue
          nil
        end
      end

      def normalize_newlines(content)
        content.to_s.gsub("\r\n", "\n")
      end

      # Deeply sanitizes invalid or malformed UTF-8 byte sequences from a string
      def clean_utf8(str)
        return str unless str.is_a?(String)
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

        if str.valid_encoding?
          begin
            return str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
          rescue StandardError
            # fallback below
          end
        end

        str.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      rescue StandardError
        begin
          str.to_s.scrub("")
        rescue
          ""
        end
      end

      # Recursively sanitizes hashes, arrays, symbols, and strings for safe UTF-8 encoding
      def clean_utf8_deep(obj, seen = nil)
        case obj
        when String
          clean_utf8(obj)
        when Hash
          seen ||= Set.new
          return "{...}" if seen.include?(obj.object_id)

          seen.add(obj.object_id)

          obj.each_with_object({}) do |(k, v), acc|
            cleaned_k = if k.is_a?(String)
                          clean_utf8(k)
                        else
                          (k.is_a?(Symbol) ? clean_utf8(k.to_s).to_sym : clean_utf8_deep(k, seen))
                        end
            acc[cleaned_k] = clean_utf8_deep(v, seen)
          end
        when Array
          seen ||= Set.new
          return "[...]" if seen.include?(obj.object_id)

          seen.add(obj.object_id)

          obj.map { |item| clean_utf8_deep(item, seen) }
        when Set
          seen ||= Set.new
          return Set.new(["[...]"]) if seen.include?(obj.object_id)

          seen.add(obj.object_id)

          obj.to_set { |item| clean_utf8_deep(item, seen) }
        when Symbol
          clean_utf8(obj.to_s).to_sym
        else
          obj
        end
      end

      # Generates JSON safely without raising JSON::GeneratorError on malformed UTF-8
      def safe_json_generate(obj, *)
        cleaned = clean_utf8_deep(obj)
        JSON.generate(cleaned, *)
      rescue JSON::GeneratorError, EncodingError, StandardError
        fallback = sanitize_for_json_fallback(obj)
        begin
          JSON.generate(fallback, *)
        rescue
          "{}"
        end
      end

      # Dumps JSON safely without raising JSON::GeneratorError on malformed UTF-8
      def safe_json_dump(obj, *)
        cleaned = clean_utf8_deep(obj)
        JSON.dump(cleaned, *)
      rescue JSON::GeneratorError, EncodingError, StandardError
        fallback = sanitize_for_json_fallback(obj)
        begin
          JSON.dump(fallback, *)
        rescue
          "{}"
        end
      end

      private

      def sanitize_for_json_fallback(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), acc|
            acc[clean_utf8(k.to_s)] = sanitize_for_json_fallback(v)
          end
        when Array
          obj.map { |item| sanitize_for_json_fallback(item) }
        when Set
          obj.map { |item| sanitize_for_json_fallback(item) }
        when String
          clean_utf8(obj)
        when Numeric, TrueClass, FalseClass, NilClass
          obj
        else
          clean_utf8(obj.to_s)
        end
      rescue StandardError
        begin
          obj.to_s.scrub("")
        rescue
          ""
        end
      end
    end
  end
end
