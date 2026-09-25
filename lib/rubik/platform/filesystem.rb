# frozen_string_literal: true

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
        tmp_file = "#{target_path}.tmp.#{::Process.pid}.#{rand(1_000_000)}"

        File.open(tmp_file, "wb") do |f|
          f.write(content)
          f.flush
          begin
            f.fsync
          rescue StandardError, ScriptError
            nil
          end
        end

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
          debug_warn("atomic_write fallback for #{target_path}: #{e.class}: #{e.message}")
          File.binwrite(target_path, content)
        ensure
          begin
            FileUtils.rm_f(tmp_file)
          rescue StandardError, ScriptError
            nil
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
