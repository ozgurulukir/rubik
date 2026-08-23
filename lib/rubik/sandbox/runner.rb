# frozen_string_literal: true

require "open3"
require "timeout"

module Rubik
  module Sandbox
    class Runner
      attr_reader :root_dir, :allow_network

      def initialize(root_dir: Dir.pwd, allow_network: false)
        @root_dir = File.expand_path(root_dir)
        @allow_network = allow_network
      end

      def run(cmd, timeout: 10, chdir: @root_dir)
        start_time = Time.now
        stdout_str = ""
        stderr_str = ""
        exit_code = 127

        env = {}
        unless @allow_network
          env["HTTP_PROXY"] = "http://127.0.0.1:9999"
          env["HTTPS_PROXY"] = "http://127.0.0.1:9999"
          env["ALL_PROXY"] = "http://127.0.0.1:9999"
        end

        begin
          Timeout.timeout(timeout) do
            Open3.popen3(env, cmd, chdir: chdir) do |_stdin, stdout, stderr, wait_thr|
              stdout_str = stdout.read
              stderr_str = stderr.read
              exit_code = wait_thr.value.exitstatus || 0
            end
          end
        rescue Timeout::Error
          stderr_str = "Sandbox execution timed out after #{timeout} seconds"
          exit_code = 124
        rescue StandardError => e
          stderr_str = "Sandbox error: #{e.message}"
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

      def isolation_level
        "rlimit+env_proxy"
      end
    end
  end
end
