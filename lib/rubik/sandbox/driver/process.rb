# frozen_string_literal: true

require_relative "base"
require_relative "../shell_resolver"
require "open3"
require "timeout"

module Rubik
  module Sandbox
    module Driver
      class ProcessDriver < Base
        def available?
          true
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0") # rubocop:disable Lint/UnusedMethodArgument -- sürücü arayüzü kwarg'leri korunuyor
          start_time = Time.now
          stdout_str = ""
          stderr_str = ""
          exit_code = 127

          # Explicit-argv spawn (Plan 55 D-1): never leave interpreter choice
          # to Open3's string form — on Windows that silently means cmd.exe.
          resolved = ShellResolver.resolve(cmd, preference: @options[:shell] || "auto")

          env = {}
          unless allow_network
            dead_proxy = "http://127.0.0.1:9999"
            env["http_proxy"] = dead_proxy
            env["https_proxy"] = dead_proxy
            env["all_proxy"] = dead_proxy
            env["no_proxy"] = ""
            env["HTTP_PROXY"] = dead_proxy
            env["HTTPS_PROXY"] = dead_proxy
            env["ALL_PROXY"] = dead_proxy
            env["NO_PROXY"] = ""
          end

          pid = nil
          begin
            Timeout.timeout(timeout) do
              Open3.popen3(env, *spawn_args_for(resolved, cmd), chdir: chdir) do |stdin, stdout, stderr, wait_thr|
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
            stderr_str = "Sandbox execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Sandbox process error: #{e.message}"
            exit_code = 1
          end

          duration = Time.now - start_time
          stderr_out = resolved[:note] ? "#{resolved[:note]}\n#{stderr_str}" : stderr_str
          {
            ok: exit_code.zero?,
            exit_code: exit_code,
            stdout: stdout_str,
            stderr: stderr_out,
            output: [stdout_str, stderr_out].reject(&:empty?).join("\n"),
            duration: duration.round(4),
            driver: "process",
            shell: resolved[:shell]
          }
        end

        private

        # cmd.exe parses its tail with its own quoting rules that standard
        # Windows argv quoting cannot express, so the command must reach it
        # as a bare string (Ruby's string spawn form routes exactly there).
        # bash/sh/pwsh take clean argv arrays.
        def spawn_args_for(resolved, cmd)
          resolved[:shell] == "cmd" ? [cmd] : resolved[:argv]
        end
      end
    end
  end
end
