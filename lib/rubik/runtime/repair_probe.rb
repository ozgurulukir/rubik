# frozen_string_literal: true

require "shellwords"
require "tempfile"
require "timeout"
require_relative "discovery"
require_relative "diagnostic_engine"
require_relative "../lsp/client"

module Rubik
  module Runtime
    # Functional checks own their resources through the caller's probe context.
    class RepairProbe
      def initialize(root_dir:)
        @root_dir = root_dir
      end

      PROBE_TIMEOUT = 5
      # These commands support help without running tests or formatting files.
      HELP_PROBE_BINARIES = ["ruby", "python", "python3", "pytest", "rspec", "rake", "bundle", "rubocop", "standardrb", "ruff", "black", "rustfmt", "cargo", "go", "gofmt",
                             "goimports", "clang-format", "zig", "prettier", "biome", "npm", "pnpm", "yarn", "bun", "mix", "dart", "crystal", "echo"].freeze

      def verify(target, lang, proposed_cmd, sub_ctx, probe_args: nil)
        return probe_failure(proposed_cmd, 1, "Unknown target component type: #{target}") unless ["lsp", "test_runner", "linter", "command"].include?(target)
        unless Rubik::Runtime::Discovery.binary_available?(proposed_cmd, root_dir: @root_dir)
          return probe_failure(proposed_cmd, 127, "Availability check failed: executable not found in PATH")
        end

        if target == "lsp"
          client = Rubik::LSP::Client.new(lang, root_dir: @root_dir, server_cmd: proposed_cmd)
          sub_ctx.on_dispose { client.stop }
          begin
            result = Timeout.timeout(PROBE_TIMEOUT) { client.start }
            return probe_failure(proposed_cmd, 1, "Functional probe failed: LSP initialize handshake rejected") unless result && client.alive?
          rescue Timeout::Error
            return probe_failure(proposed_cmd, 124, "LSP initialize handshake timed out")
          end
          return [true, nil]
        end

        argv = Shellwords.split(proposed_cmd)
        if probe_args.nil?
          unless HELP_PROBE_BINARIES.include?(File.basename(argv.first.to_s))
            return probe_failure(proposed_cmd, 1, "Available but unverified: provide non-mutating probe_args for this executable")
          end

          probe_args = ["--help"]
        end
        return probe_failure(proposed_cmd, 1, "probe_args must be a non-empty array of strings") unless probe_args.is_a?(Array) && !probe_args.empty? && probe_args.all?(String)

        argv.concat(probe_args)
        # Array-form spawn never interprets shell operators. File-backed output
        # avoids pipe-reader threads surviving a timeout or a forked descendant.
        output = Tempfile.new("rubik-repair-probe")
        sub_ctx.on_dispose { output.close! }
        options = { chdir: @root_dir, in: File::NULL, out: output, err: output }
        options[:pgroup] = true unless Rubik::Platform.windows?
        pid = Process.spawn(*argv, **options)
        reaped = false
        sub_ctx.on_dispose do
          if Rubik::Platform.windows?
            Rubik::Platform.kill_tree(pid) unless reaped
          else
            begin
              Process.kill("KILL", -pid)
            rescue Errno::ESRCH
              nil
            end
          end
          Process.waitpid(pid) unless reaped
        rescue Errno::ECHILD
          nil
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROBE_TIMEOUT
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            reaped = true
            status = waited.last
            return [true, nil] if status.success?

            output.rewind
            return probe_failure(proposed_cmd, status.exitstatus || 1, "Functional probe failed: #{output.read(4096)}")
          end
          return probe_failure(proposed_cmd, 124, "Functional probe timed out") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        end
      end

      private

      def probe_failure(command, code, message)
        [false, Rubik::Runtime::DiagnosticEngine.diagnose(cmd: command, exit_code: code, stderr: message)]
      end
    end
  end
end
