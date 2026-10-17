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
            stdout: res[:stdout],
            stderr: res[:stderr],
            output: res[:output],
            duration: res[:duration],
            driver: "podman"
          }
        end
      end
    end
  end
end
