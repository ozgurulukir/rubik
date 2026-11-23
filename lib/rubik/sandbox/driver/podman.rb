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
      class PodmanDriver < Base
        DEFAULT_IMAGE = "rubik-sandbox:latest"

        def available?
          !Rubik::Platform.which("podman").nil?
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          # Defense-in-depth (issue #591): re-run the shared session guard
          # before spawning, the same way ProcessDriver does, so a caller
          # that forgot its own pre-check is still gated by operator policy.
          verify_command_safety!(cmd)

          image = @options[:image] || DEFAULT_IMAGE
          workspace = File.expand_path(chdir)
          container_name = "rubik-box-#{SecureRandom.hex(6)}"

          podman_args = [
            "podman", "run", "--rm",
            "--name", container_name,
            *CONTAINER_HARDENING_FLAGS,
            "-w", "/workspace",
            "-v", "#{workspace}:/workspace:rw",
            *allowed_dir_mounts,
            "--memory", "#{memory_limit_mb}m",
            "--cpus", cpus.to_s,
            "--pids-limit", "100"
          ]

          podman_args.push("--network", "none") unless allow_network
          podman_args.push(image, "sh", "-c", cmd)

          res = begin
            Rubik::Platform.popen_capture(
              *podman_args,
              timeout: timeout,
              chdir: workspace,
              timeout_message: "Podman sandbox execution timed out after #{timeout} seconds",
              error_message: "Podman sandbox error"
            )
          ensure
            # Mirror DockerDriver: the watchdog kills the podman client process
            # tree on timeout, and --rm removal is performed by that client, so
            # a timed-out run would otherwise orphan the container. Best-effort
            # cleanup; a failed `podman rm -f` leaves a trace.
            removed = system("podman", "rm", "-f", container_name, out: File::NULL, err: File::NULL)
            Rubik::Log.warn(:sandbox, "podman container '#{container_name}' could not be removed") unless removed
          end

          finalize_result(res, driver: "podman")
        end
      end
    end
  end
end
