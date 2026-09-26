# frozen_string_literal: true

require_relative "base"
require_relative "../../platform"
require "open3"
require "timeout"

require "securerandom"

module Rubik
  module Sandbox
    module Driver
      class DockerDriver < Base
        DEFAULT_IMAGE = "rubik-sandbox:latest"

        def available?
          !Rubik::Platform.which("docker").nil? && system("docker ps > #{Rubik::Platform.dev_null} 2>&1")
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          start_time = Time.now
          image = @options[:image] || DEFAULT_IMAGE
          workspace = File.expand_path(chdir)
          container_name = "rubik-box-#{SecureRandom.hex(6)}"

          docker_args = [
            "docker", "run", "--rm",
            "--name", container_name,
            "--read-only",
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--tmpfs", "/tmp:rw,noexec,nosuid",
            "-w", "/workspace",
            "-v", "#{workspace}:/workspace:rw",
            "--memory", "#{memory_limit_mb}m",
            "--cpus", cpus.to_s,
            "--pids-limit", "100"
          ]

          docker_args.push("--network", "none") unless allow_network
          docker_args.push(image, "sh", "-c", cmd)

          stdout_str = ""
          stderr_str = ""
          exit_code = 127
          wait_thr_ref = nil

          begin
            Timeout.timeout(timeout) do
              Open3.popen3(*docker_args) do |stdin, stdout, stderr, wait_thr|
                wait_thr_ref = wait_thr
                begin
                  stdin.close
                rescue StandardError
                  nil
                end
                t_out = Thread.new do
                  stdout.read
                rescue StandardError
                  ""
                end
                t_err = Thread.new do
                  stderr.read
                rescue StandardError
                  ""
                end
                begin
                  stdout_str = t_out.value.to_s
                  stderr_str = t_err.value.to_s
                  status = wait_thr.value
                  exit_code = status.exitstatus || (status.signaled? ? (128 + (status.termsig || 1)) : 1)
                ensure
                  begin
                    t_out.kill
                  rescue StandardError
                    nil
                  end
                  begin
                    t_err.kill
                  rescue StandardError
                    nil
                  end
                end
              end
            end
          rescue Timeout::Error
            Rubik::Platform.kill_tree(wait_thr_ref.pid) if wait_thr_ref.respond_to?(:pid) && wait_thr_ref.pid
            system("docker rm -f #{container_name} > #{Rubik::Platform.dev_null} 2>&1")
            stderr_str = "Docker sandbox execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Docker sandbox error: #{e.message}"
            exit_code = 1
          ensure
            Rubik::Platform.kill_tree(wait_thr_ref.pid) if wait_thr_ref.respond_to?(:pid) && wait_thr_ref.pid
            system("docker rm -f #{container_name} > #{Rubik::Platform.dev_null} 2>&1")
          end

          duration = Time.now - start_time
          {
            ok: exit_code.zero?,
            exit_code: exit_code,
            stdout: stdout_str,
            stderr: stderr_str,
            output: [stdout_str, stderr_str].reject(&:empty?).join("\n"),
            duration: duration.round(4),
            driver: "docker"
          }
        end
      end
    end
  end
end
