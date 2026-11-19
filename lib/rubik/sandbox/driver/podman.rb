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
          # Defense-in-depth (issue #591): re-run the shared session guard
          # before spawning, the same way ProcessDriver does, so a caller
          # that forgot its own pre-check is still gated by operator policy.
          verify_command_safety!(cmd)

          image = @options[:image] || DEFAULT_IMAGE
          workspace = File.expand_path(chdir)

          podman_args = [
            "podman", "run", "--rm",
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

          res = Rubik::Platform.popen_capture(
            *podman_args,
            timeout: timeout,
            chdir: workspace,
            timeout_message: "Podman sandbox execution timed out after #{timeout} seconds",
            error_message: "Podman sandbox error"
          )

          {
            ok: res[:ok],
            exit_code: res[:exit_code],
            # Explicit timeout flag plumbed to the tool layer (#597-3).
            timed_out: res[:timed_out] == true,
            stdout: res[:stdout],
            stderr: res[:stderr],
            output: res[:output],
            duration: res[:duration],
            driver: "podman"
          }
        end

        private

        # Issue #591: bind-mount every configured allowed dir read-write,
        # mirroring BubblewrapDriver's loop, so commands legitimately touching
        # an allowed external dir work identically across drivers.
        def allowed_dir_mounts
          Array(@options[:allowed_dirs]).filter_map do |dir|
            expanded = File.expand_path(dir.to_s)
            next unless File.directory?(expanded)

            ["-v", "#{expanded}:#{expanded}:rw"]
          end.flatten
        end
      end
    end
  end
end
