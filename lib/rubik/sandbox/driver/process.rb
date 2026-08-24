# frozen_string_literal: true

require_relative "base"
require "open3"
require "timeout"

module Rubik
  module Sandbox
    module Driver
      class ProcessDriver < Base
        def available?
          true
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          start_time = Time.now
          stdout_str = ""
          stderr_str = ""
          exit_code = 127

          env = {}
          unless allow_network
            env["HTTP_PROXY"] = "http://127.0.0.1:9999"
            env["HTTPS_PROXY"] = "http://127.0.0.1:9999"
            env["ALL_PROXY"] = "http://127.0.0.1:9999"
          end

          pid = nil
          begin
            Timeout.timeout(timeout) do
              Open3.popen3(env, cmd, chdir: chdir) do |_stdin, stdout, stderr, wait_thr|
                pid = wait_thr.pid
                stdout_str = stdout.read
                stderr_str = stderr.read
                exit_code = wait_thr.value.exitstatus || 0
              end
            end
          rescue Timeout::Error
            Rubik::Platform.kill_tree(pid) if pid
            stderr_str = "Sandbox execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Sandbox process error: #{e.message}"
            exit_code = 1
          end

          duration = Time.now - start_time
          {
            ok: exit_code == 0,
            exit_code: exit_code,
            stdout: stdout_str,
            stderr: stderr_str,
            output: [stdout_str, stderr_str].reject(&:empty?).join("\n"),
            duration: duration.round(4),
            driver: "process"
          }
        end
      end
    end
  end
end
