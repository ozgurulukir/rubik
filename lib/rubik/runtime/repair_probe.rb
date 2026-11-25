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
      ALLOWED_PROBE_FLAGS = ["--help", "-h", "help", "--version", "-v", "-V", "version", "--status"].freeze

      def initialize(root_dir:, guard: nil)
        @root_dir = root_dir
        @guard = guard
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

        guard_failure = guard_rejection(proposed_cmd)
        return guard_failure if guard_failure

        return probe_lsp(lang, proposed_cmd, sub_ctx) if target == "lsp"

        probe_executable(proposed_cmd, sub_ctx, probe_args: probe_args)
      end

      private

      # Security-gate phase: run the operator's command guard (when wired)
      # before any probe can spawn. Returns the probe_failure pair on a
      # BlockedWriteError, or nil when the command passed (or no guard is
      # configured).
      def guard_rejection(proposed_cmd)
        return nil unless @guard

        cmd_to_check = proposed_cmd.is_a?(Hash) ? [proposed_cmd[:executable], *Array(proposed_cmd[:args])].join(" ") : proposed_cmd.to_s
        begin
          @guard.verify_command_safety!(cmd_to_check)
        rescue Rubik::Security::BlockedWriteError => e
          probe_failure(proposed_cmd, 1, "Proposed command blocked by security guard: #{e.message}")
        end
      end

      # LSP probe phase: a full initialize handshake against the proposed
      # server, hard-capped at PROBE_TIMEOUT. The client's lifetime is bound
      # to the caller's probe context via a dispose inverse, so a rejected or
      # timed-out handshake never leaks a server process.
      def probe_lsp(lang, proposed_cmd, sub_ctx)
        client = Rubik::LSP::Client.new(lang, root_dir: @root_dir, server_cmd: proposed_cmd)
        sub_ctx.on_dispose { client.stop }
        begin
          result = Timeout.timeout(PROBE_TIMEOUT) { client.start }
          return probe_failure(proposed_cmd, 1, "Functional probe failed: LSP initialize handshake rejected") unless result && client.alive?
        rescue Timeout::Error
          return probe_failure(proposed_cmd, 124, "LSP initialize handshake timed out")
        end
        [true, nil]
      end

      # Executable probe phase for test_runner/linter/command targets: select
      # safe diagnostic probe_args (defaulting known help-capable binaries to
      # --help), then hand the validated argv to the spawn phase.
      def probe_executable(proposed_cmd, sub_ctx, probe_args:)
        argv = Shellwords.split(proposed_cmd)
        if probe_args.nil?
          unless HELP_PROBE_BINARIES.include?(File.basename(argv.first.to_s))
            return probe_failure(proposed_cmd, 1, "Available but unverified: provide non-mutating probe_args for this executable")
          end

          probe_args = ["--help"]
        else
          return probe_failure(proposed_cmd, 1, "probe_args must be a non-empty array of strings") unless probe_args.is_a?(Array) && !probe_args.empty? && probe_args.all?(String)

          disallowed = probe_args.reject { |arg| ALLOWED_PROBE_FLAGS.include?(arg) }
          if disallowed.any?
            return probe_failure(proposed_cmd, 1, "Disallowed probe_args: only safe diagnostic flags #{ALLOWED_PROBE_FLAGS.inspect} are allowed (got: #{disallowed.inspect})")
          end
        end

        run_probe_process(argv, probe_args, proposed_cmd, sub_ctx)
      end

      # Spawn + reap phase: the probe runs array-form so no shell operators
      # are ever interpreted; output goes to a file so no pipe-reader thread
      # survives a timeout or a forked descendant. The kill/reap dispose
      # inverse and the polling loop share the reaped flag, so the process is
      # killed and reaped exactly once whichever side wins the race.
      def run_probe_process(argv, probe_args, proposed_cmd, sub_ctx)
        argv.concat(probe_args)
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

      def probe_failure(command, code, message)
        [false, Rubik::Runtime::DiagnosticEngine.diagnose(cmd: command, exit_code: code, stderr: message)]
      end
    end
  end
end
