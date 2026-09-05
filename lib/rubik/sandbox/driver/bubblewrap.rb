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
          start_time = Time.now
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

          stdout_str = ""
          stderr_str = ""
          exit_code = 127
          pid = nil

          begin
            Timeout.timeout(timeout) do
              Open3.popen3(*bwrap_cmd) do |stdin, stdout, stderr, wait_thr|
                pid = wait_thr.pid
                begin
                  stdin.close
                rescue
                  nil
                end
                t_out = Thread.new do
                  stdout.read
                rescue
                  ""
                end
                t_err = Thread.new do
                  stderr.read
                rescue
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
                  rescue
                    nil
                  end
                  begin
                    t_err.kill
                  rescue
                    nil
                  end
                end
              end
            end
          rescue Timeout::Error
            Rubik::Platform.kill_tree(pid) if pid
            stderr_str = "Bubblewrap execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Bubblewrap execution error: #{e.message}"
            exit_code = 1
          end

          duration = Time.now - start_time
          {
            ok: exit_code.zero?,
            exit_code: exit_code,
            stdout: stdout_str,
            stderr: stderr_str,
            output: [stdout_str, stderr_str].reject(&:empty?).join("\n"),
            duration: duration.round(4),
            driver: "bwrap"
          }
        end
      end
    end
  end
end
