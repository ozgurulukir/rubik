# frozen_string_literal: true

require "open3"
require "timeout"

module Rubik
  module Adapter
    class ProcessRunner
      def self.run(cmd, timeout: 15, chdir: Dir.pwd)
        start_time = Time.now
        stdout_str = ""
        stderr_str = ""
        exit_code = 127

        begin
          Timeout.timeout(timeout) do
            stdout_str, stderr_str, status = Open3.capture3(cmd, chdir: chdir)
            exit_code = status.exitstatus || 0
          end
        rescue Timeout::Error
          stderr_str = "Execution timed out after #{timeout} seconds"
          exit_code = 124
        rescue Errno::ENOENT => e
          stderr_str = "Binary not found: #{e.message}"
          exit_code = 127
        rescue StandardError => e
          stderr_str = "Execution error: #{e.message}"
          exit_code = 1
        end

        duration = Time.now - start_time
        {
          ok: exit_code == 0,
          exit_code: exit_code,
          stdout: stdout_str,
          stderr: stderr_str,
          output: [stdout_str, stderr_str].reject(&:empty?).join("\n"),
          duration: duration.round(4)
        }
      end
    end
  end
end
