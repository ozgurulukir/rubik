# frozen_string_literal: true

require_relative "base"
require_relative "../shell_resolver"
require_relative "../../security/guard" unless defined?(Rubik::Security::Guard)
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
          # Direct host execution does NOT inject misleading dead proxy variables (127.0.0.1:9999).
          # Hardware/namespace network isolation is only provided when a true sandbox
          # (Bubblewrap, Docker, Podman) is enabled.

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
            stderr_str = "Execution timed out after #{timeout} seconds"
            exit_code = 124
          rescue StandardError => e
            stderr_str = "Execution error: #{e.message}"
            exit_code = 1
          end

          duration = Time.now - start_time
          stderr_out = resolved[:note] ? "#{resolved[:note]}\n#{stderr_str}" : stderr_str
          require_relative "../../security/redactor" unless defined?(Rubik::Security::Redactor)
          clean_stdout = Rubik::Security::Redactor.redact(stdout_str)
          clean_stderr = Rubik::Security::Redactor.redact(stderr_out)
          {
            ok: exit_code.zero?,
            exit_code: exit_code,
            stdout: clean_stdout,
            stderr: clean_stderr,
            output: [clean_stdout, clean_stderr].reject(&:empty?).join("\n"),
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
        #
        # DEFENSE-IN-DEPTH (this closure, not a residual gap): the classifier
        # runs in the ProcessDriver guard (lib/rubik/security/guard) and gates
        # every spawn BEFORE this method is called, so a dangerous command
        # never reaches spawn. But the classifier in the guard classifies the
        # RAW `cmd` string with POSIX Shellwords and a nil shell. When the
        # resolved shell is "cmd" cmd.exe re-parses the tail with its own
        # grammar, so a command the classifier deemed "safe" under POSIX could
        # be re-interpreted (e.g. the cmd builtin `start http://x && evil.exe`
        # — `start` opens a URL, then `&&` chains the second program). To close
        # that split we (1) re-run the guard's classification with the cmd shell
        # hint right here, BEFORE spawning, and (2) explicitly block the cmd.exe
        # builtins and drive-letter destructive constructs that the POSIX
        # classifier can misread as safe. A POSIX-safe command that is
        # dangerous under cmd.exe is therefore rejected and never spawned.
        def spawn_args_for(resolved, cmd)
          resolved[:shell] == "cmd" ? verify_cmd_safe(cmd) : resolved[:argv]
        end

        # Guard the cmd.exe branch. Re-classifies with shell: "cmd" so the guard
        # applies cmd.exe semantics (builtins, quoting) rather than POSIX ones,
        # and explicitly blocks the builtins/drive constructs the POSIX
        # classifier can misread as safe. A command POSIX-safe but
        # cmd.exe-dangerous must NOT be spawned.
        def verify_cmd_safe(cmd)
          # SAFETY ORDER (critical): the global classifier/allowlist/fatal-regex
          # check MUST run BEFORE any cmd-specific approval. verify_command_safety!
          # gates every spawn on the operator allowlist and the catastrophic
          # fallback regex, so nothing the classifier rejects can ever reach the
          # spawn path — even though the cmd-specific check below could approve
          # it. Reversing this order would let a cmd-specific construct bypass
          # the allowlist (HIGH finding). verify_cmd_specific_safe! is only a
          # late-stage refinement: it may tighten an already-approved command,
          # never authorize one the classifier rejected.
          verify_command_safety!(cmd, shell: "cmd")
          verify_cmd_specific_safe!(cmd)
          [cmd]
        end

        # cmd.exe builtins / constructs that POSIX Shellwords would treat as a
        # harmless word or redirect but cmd.exe executes with special (often
        # dangerous) meaning. Guarded behind windows? so non-Windows hosts (where
        # a cmd branch never resolves) are unaffected.
        CMD_DANGEROUS_CONSTRUCTS = [
          /(?:\A|[&|;])\s*(?:start|call|goto)\b/i, # launch / subroutine / jump builtins
          /\b(?:del|erase|rmdir)\b\s+.*[a-z]:\\/i, # drive-letter file removal
          />\s*[a-z]:\\/i # output redirect to a drive-letter path (overwrite)
        ].freeze
        private_constant :CMD_DANGEROUS_CONSTRUCTS

        def verify_cmd_specific_safe!(cmd)
          return unless Rubik::Platform.windows?
          return unless CMD_DANGEROUS_CONSTRUCTS.any? { |p| cmd.to_s.match?(p) }

          raise_dangerous(cmd.to_s, rule_name: "cmd.exe_construct")
        end

        # Security guard gating cmd.exe spawns. The Runner injects the shared
        # session guard via driver_opts (options[:guard]) so operator policy —
        # the live command allowlist above all — applies here too; the lazy
        # local fallback (silent audit, zero policy) serves only standalone /
        # test-constructed drivers.
        def guard
          @options[:guard] || (@guard ||= Rubik::Security::Guard.new(audit_log_path: nil))
        end

        # Re-run the security guard's classification, scoped to the given shell
        # so cmd.exe semantics are enforced when spawned via cmd. Blocks a
        # POSIX-safe-but-cmd-dangerous command with BlockedWriteError.
        def verify_command_safety!(cmd, shell: nil)
          guard.verify_command_safety!(cmd, shell: shell)
          true
        end

        # Raise the standard BlockedWriteError used throughout the guard
        # surface for an explicitly detected dangerous construct.
        def raise_dangerous(cmd, rule_name:)
          raise Rubik::Security::BlockedWriteError.new(
            "Dangerous command execution blocked: #{cmd}",
            kind: :cmd_construct,
            blocked_command: cmd,
            rule_name: rule_name
          )
        end
      end
    end
  end
end
