# frozen_string_literal: true

require_relative "base"
require_relative "../../platform"
require "open3"
require "timeout"

module Rubik
  module Sandbox
    module Driver
      class BubblewrapDriver < Base
        def name
          "bwrap"
        end

        def available?
          Rubik::Platform.linux? && !Rubik::Platform.which("bwrap").nil?
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0") # rubocop:disable Lint/UnusedMethodArgument
          workspace = File.expand_path(chdir)

          bwrap_cmd = [
            "bwrap",
            "--ro-bind", "/", "/",
            "--dev", "/dev",
            "--proc", "/proc",
            "--tmpfs", "/tmp",
            "--bind", workspace, workspace
          ]

          if @options[:allowed_dirs]
            Array(@options[:allowed_dirs]).each do |dir|
              expanded = File.expand_path(dir.to_s)
              bwrap_cmd.push("--bind", expanded, expanded) if File.directory?(expanded)
            end
          end

          bwrap_cmd.push("--chdir", workspace)
          bwrap_cmd.push("--unshare-net") unless allow_network
          bwrap_cmd.push("--unshare-pid", "--die-with-parent")
          bwrap_cmd.push("sh", "-c", cmd)

          res = Rubik::Platform.popen_capture(
            *bwrap_cmd,
            timeout: timeout,
            chdir: workspace,
            timeout_message: "Bubblewrap execution timed out after #{timeout} seconds",
            error_message: "Bubblewrap execution error"
          )

          {
            ok: res[:ok],
            exit_code: res[:exit_code],
            stdout: res[:stdout],
            stderr: res[:stderr],
            output: res[:output],
            duration: res[:duration],
            driver: "bwrap"
          }
        end
      end
    end
  end
end
