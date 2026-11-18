# frozen_string_literal: true

require "securerandom"

module Rubik
  module Platform
    # File system operations (atomic writes, newline normalization).
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module FileSystem
      def self.included(base)
        base.extend self
      end

      def atomic_write(target_path, content)
        dir = File.dirname(target_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)

        # Preserve the target's permission bits (issue #543): File.open creates
        # a 0644 temp file and rename keeps the temp's mode, so overwriting a
        # 0600 secret would expose it and a 0755 script would lose +x. Capture
        # the mode before writing and carry it onto the temp file before rename.
        existing_mode = begin
          stat = File.stat(target_path)
          stat.mode & 0o7777 if stat.file?
        rescue Errno::ENOENT
          nil
        end

        # O_EXCL refuses a pre-placed path (including a symlink) instead of
        # following it, and the random suffix makes the temp name unpredictable.
        # Together they close the TOCTOU/symlink redirection of issue #543.
        tmp_file = "#{target_path}.tmp.#{::Process.pid}.#{SecureRandom.hex(12)}"
        created = false

        begin
          # Mode 0o600 keeps the in-flight temp private until the final chmod.
          File.open(tmp_file, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |f|
            created = true
            f.write(content)
            f.flush
            begin
              f.fsync
            rescue StandardError, ScriptError
              nil
            end
          end

          File.chmod(existing_mode, tmp_file) if existing_mode

          # Atomic replace: rename tmp_file -> target_path without unlinking first
          # (closing TOCTOU). Retry for Windows transient locks.
          retries = 3
          begin
            File.rename(tmp_file, target_path)
          rescue SystemCallError => e
            if retries.positive?
              retries -= 1
              sleep 0.02
              retry
            end
            debug_warn("atomic_write failed for #{target_path}: #{e.class}: #{e.message}")
            raise
          end
        ensure
          # Only remove the temp file we created; never delete a pre-placed
          # path (e.g. an attacker's symlink) that made O_EXCL fail.
          if created
            begin
              FileUtils.rm_f(tmp_file)
            rescue StandardError, ScriptError
              nil
            end
          end
        end
      end

      def normalize_newlines(content)
        content.to_s.gsub("\r\n", "\n")
      end

      # UTF-8 read path for project files: tags the bytes as UTF-8 regardless
      # of the OS default external encoding (Windows codepages must not leak
      # into Rubik's pipeline) and scrubs invalid sequences so the model,
      # history, and regex consumers never receive broken encoding. All
      # buffer hash computations share this path, so a broken-encoding file
      # shifts its digest once and then stays stable.
      def read_text(path)
        Rubik::Platform.safe_utf8(File.read(path, encoding: "UTF-8"))
      end
    end
  end
end
