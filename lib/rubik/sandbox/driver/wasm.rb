# frozen_string_literal: true

require_relative "base"
require "open3"
require "timeout"

module Rubik
  module Sandbox
    module Driver
      class WasmDriver < Base
        RUNTIMES = %w[wasmtime wasmer].freeze

        def available?
          RUNTIMES.any? { |rt| system("which #{rt} > /dev/null 2>&1") }
        end

        def runtime_bin
          RUNTIMES.find { |rt| system("which #{rt} > /dev/null 2>&1") } || "wasmtime"
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          start_time = Time.now
          rt = @options[:runtime] || runtime_bin
          workspace = File.expand_path(chdir)

          # If the command starts with a .wasm file or direct wasm invocation
          wasm_args = [rt, "--dir", workspace]
          wasm_args.push("--disable-cache") if rt == "wasmtime"

          # Format command
          if cmd.include?(".wasm")
            parts = cmd.split(/\s+/)
            wasm_file = parts.first
            rest_args = parts[1..] || []
            wasm_args.push(wasm_file, *rest_args)
          else
            # For non-wasm scripts, invoke via Wasm guest runner if available
            wasm_args.push(cmd)
          end

          stdout_str = ""
          stderr_str = ""
          exit_code = 127

          begin
            Timeout.timeout(timeout) do
              Open3.popen3(*wasm_args, chdir: workspace) do |_stdin, stdout, stderr, wait_thr|
                stdout_str = stdout.read
                stderr_str = stderr.read
                exit_code = wait_thr.value.exitstatus || 0
              end
            end
          rescue Timeout::Error
            stderr_str = "Wasm execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Wasm execution error: #{e.message}"
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
            driver: "wasm"
          }
        end
      end
    end
  end
end
