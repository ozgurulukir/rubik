# frozen_string_literal: true

require_relative "base"
require_relative "../../platform"
require "open3"
require "timeout"

module Rubik
  module Sandbox
    module Driver
      class PodmanDriver < Base
        DEFAULT_IMAGE = "rubik-sandbox:latest"

        def available?
          !Rubik::Platform.which("podman").nil?
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          start_time = Time.now
          image = @options[:image] || DEFAULT_IMAGE
          workspace = File.expand_path(chdir)

          podman_args = [
            "podman", "run", "--rm",
            "-w", "/workspace",
            "-v", "#{workspace}:/workspace:rw",
            "--memory", "#{memory_limit_mb}m",
            "--cpus", cpus.to_s,
            "--pids-limit", "100"
          ]

          podman_args.push("--network", "none") unless allow_network
          podman_args.push(image, "sh", "-c", cmd)

          stdout_str = ""
          stderr_str = ""
          exit_code = 127

          begin
            Timeout.timeout(timeout) do
              Open3.popen3(*podman_args) do |_stdin, stdout, stderr, wait_thr|
                stdout_str = stdout.read
                stderr_str = stderr.read
                exit_code = wait_thr.value.exitstatus || 0
              end
            end
          rescue Timeout::Error
            stderr_str = "Podman sandbox execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Podman sandbox error: #{e.message}"
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
            driver: "podman"
          }
        end
      end
    end
  end
end
