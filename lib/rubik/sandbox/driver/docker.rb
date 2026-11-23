# frozen_string_literal: true

require_relative "base"
require_relative "../../platform"
require_relative "../../log"
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
          # Defense-in-depth (issue #591): re-run the shared session guard
          # before spawning, the same way ProcessDriver does, so a caller
          # that forgot its own pre-check is still gated by operator policy.
          verify_command_safety!(cmd)

          image = @options[:image] || DEFAULT_IMAGE
          workspace = File.expand_path(chdir)
          container_name = "rubik-box-#{SecureRandom.hex(6)}"

          docker_args = [
            "docker", "run", "--rm",
            "--name", container_name,
            *CONTAINER_HARDENING_FLAGS,
            "-w", "/workspace",
            "-v", "#{workspace}:/workspace:rw",
            *allowed_dir_mounts,
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
            # Best-effort cleanup, but a failed `docker rm -f` leaves an
            # orphaned container — check the result and leave a trace.
            removed = system("docker", "rm", "-f", container_name, out: File::NULL, err: File::NULL)
            Rubik::Log.warn(:sandbox, "docker container '#{container_name}' could not be removed") unless removed
          end

          finalize_result(res, driver: "docker")
        end
      end
    end
  end
end
