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
          !Rubik::Platform.which("docker").nil? && system("docker", "ps", out: File::NULL, err: File::NULL)
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
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

          res = begin
            Rubik::Platform.popen_capture(
              *docker_args,
              timeout: timeout,
              chdir: workspace,
              timeout_message: "Docker sandbox execution timed out after #{timeout} seconds",
              error_message: "Docker sandbox error"
            )
          ensure
            system("docker", "rm", "-f", container_name, out: File::NULL, err: File::NULL)
          end

          {
            ok: res[:ok],
            exit_code: res[:exit_code],
            stdout: res[:stdout],
            stderr: res[:stderr],
            output: res[:output],
            duration: res[:duration],
            driver: "docker"
          }
        end
      end
    end
  end
end
