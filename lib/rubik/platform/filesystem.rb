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
        tmp_file = "#{target_path}.tmp.#{::Process.pid}.#{rand(100_000)}"
        File.write(tmp_file, content)

        if File.exist?(target_path)
          begin
            File.unlink(target_path)
          rescue
            nil
          end
        end

        begin
          File.rename(tmp_file, target_path)
        rescue StandardError => e
          # Atomic path failed (cross-device rename, perms); fall back to a plain write.
          debug_warn("atomic_write fallback for #{target_path}: #{e.class}: #{e.message}")
          File.write(target_path, content)
        ensure
          begin
            FileUtils.rm_f(tmp_file)
          rescue
            nil
          end
        end
      end

      def normalize_newlines(content)
        content.to_s.gsub("\r\n", "\n")
      end
    end
  end
end
