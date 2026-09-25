# frozen_string_literal: true

require "json"
require "rbconfig"
require "stringio"
require "timeout"

require_relative "../security/errors"

module Rubik
  module Tools
    # Runs synthesized handler code in a short-lived child ruby process with a
    # hard kill deadline (AGENTS.md §3.4 Session Isolation).
    #
    # Why a subprocess: Timeout.timeout relies on Thread.raise, which cannot
    # preempt C extensions or uninterruptible blocking syscalls — a runaway
    # handler could hang the whole REPL past its budget. A child process can
    # always be killed. When spawning is impossible (exotic embeddings, strict
    # sandboxes) the runner reports :spawn_failed so callers can fall back to
    # the in-process Timeout path.
    module PreflightRunner
      DEFAULT_TIMEOUT = 5

      # Child evaluator: reads {code:, args:, mode:} from stdin, calls the
      # handler, prints a single JSON verdict line. Single-quoted heredoc —
      # never interpolated into the parent's source.
      CHILD_SCRIPT = <<~'RUBY'
        require "json"
        require "stringio"
        begin
          payload = JSON.parse($stdin.read)
          handler = RubyVM::InstructionSequence.compile(payload["code"]).eval # rubocop:disable Security/Eval -- preflight child evaluator; code verified by Guard in parent before spawn
          raise "code did not evaluate to a callable Proc" unless handler.respond_to?(:call)
          # 2-arity command handlers receive the live CommandContext at
          # dispatch; preflight mirrors its OUTPUT VIEW (out/puts/print/
          # flush delegate to a throwaway StringIO) without the repl/
          # require. Service reads fail loudly here — such handlers should
          # declare 3-arity and be verified with the raw shell instead.
          command_view = Struct.new(:out) do
            def puts(*args)
              out.puts(*args)
            end

            def print(*args)
              out.print(*args)
            end

            def flush
              out.flush if out.respond_to?(:flush)
            end
          end
          case payload["mode"]
          when "tool"
            handler.call(payload["args"])
          else
            view = command_view.new(StringIO.new)
            case handler.arity
            when 1 then handler.call(payload["args"])
            when 2 then handler.call(payload["args"], view)
            else handler.call(payload["args"], view.out, nil)
            end
          end
          STDOUT.puts JSON.dump(ok: true)
        rescue StandardError, ScriptError => e
          STDOUT.puts JSON.dump(ok: false, error: "#{e.class}: #{e.message}")
        end
      RUBY

      module_function

      # Executes +code+ (a self-contained lambda) with +args+ in an isolated
      # child process. mode: :tool mirrors the ToolWrapper contract (exactly
      # one argument); :command mirrors the REPL arity dispatch (args, out,
      # nil shell — the real shell is unavailable in the child).
      #
      # The child process has no Rubik loaded, so payload["code"] cannot be
      # verified there — the ONLY verification it can rely on is whatever
      # the parent proved BEFORE spawning. guard is a REQUIRED kwarg on
      # purpose: a future caller cannot skip the spawn-boundary check
      # silently (ArgumentError at the call site).
      #
      # Returns nil on success, an error-detail String on failure, or
      # :spawn_failed when the child infrastructure is unusable.
      def run(code, args, mode: :command, timeout: DEFAULT_TIMEOUT, guard:)
        # The duck-typed fallback is a test-double affordance: production
        # guards always define verify_synthesis_safety! (the synthesis
        # builtin ran the same check before eval, so preflight adds no new
        # bypass here).
        if guard.respond_to?(:verify_synthesis_safety!)
          guard.verify_synthesis_safety!(code)
        else
          guard.verify_command_safety!(code)
        end
        payload = JSON.dump(code: code, args: args || {}, mode: mode.to_s)
        run_subprocess(payload, timeout)
      rescue Rubik::Security::BlockedWriteError => e
        # Must precede the generic rescue: BlockedWriteError is a
        # StandardError, and a block verdict downgraded to :spawn_failed
        # would make the caller's in-process fallback run the blocked code.
        "security verification failed: #{e.message}"
      rescue StandardError
        # Non-JSON-serializable args (TypeError/GeneratorError) or any other
        # payload problem — caller falls back to in-process.
        :spawn_failed
      end

      # In-process fallback (subprocess unavailable). Yields the caller's
      # verification block under a Timeout guard. Returns nil on success or
      # an error-detail String. Same caveat as before: Timeout cannot preempt
      # C extensions or uninterruptible syscalls.
      def verify_in_process(timeout: DEFAULT_TIMEOUT, &)
        Timeout.timeout(timeout, &)
        nil
      rescue Timeout::Error
        "execution timed out after #{timeout} seconds"
      rescue StandardError, ScriptError => e
        "#{e.class}: #{e.message}"
      end

      # Parent-side mirror of the child evaluator's dispatch (see CHILD_SCRIPT).
      # Keeps the fallback path semantically identical to the subprocess path.
      def call_handler(handler, args, mode: :command, shell: nil)
        if mode == :tool
          handler.call(args)
        else
          command_view = Struct.new(:out) do
            def puts(*args)
              out.puts(*args)
            end

            def print(*args)
              out.print(*args)
            end

            def flush
              out.flush if out.respond_to?(:flush)
            end
          end
          view = command_view.new(StringIO.new)
          case handler.arity
          when 1 then handler.call(args)
          when 2 then handler.call(args, view)
          else handler.call(args, view.out, shell)
          end
        end
      end

      def run_subprocess(payload, timeout)
        rd_in = wr_in = rd_out = wr_out = nil
        rd_in, wr_in = IO.pipe
        rd_out, wr_out = IO.pipe
        pid = Process.spawn(RbConfig.ruby, "-e", CHILD_SCRIPT, in: rd_in, out: wr_out, err: File::NULL)
        rd_in.close
        wr_out.close
        wr_in.write(payload)
        wr_in.close

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        output = +""
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            kill_child(pid)
            return "execution timed out after #{timeout} seconds (subprocess killed)"
          end
          # wait_readable returning false (deadline slice elapsed) must NOT
          # break: the deadline check above is what kills a runaway child.
          next unless rd_out.wait_readable(remaining)

          chunk = rd_out.read_nonblock(4096, exception: false)
          break if chunk.nil? # EOF — child finished
          next if chunk == :wait_readable

          output << chunk
        end
        begin
          Process.wait(pid)
        rescue StandardError
          nil
        end
        parse_verdict(output)
      rescue StandardError
        kill_child(pid) if defined?(pid) && pid
        :spawn_failed
      ensure
        [rd_in, wr_in, rd_out, wr_out].each do |io|
          io.close unless io.nil? || io.closed?
        rescue StandardError
          nil
        end
      end

      def kill_child(pid)
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue StandardError
        nil
      end

      def parse_verdict(output)
        line = output.lines.reverse.find { |l| l.start_with?("{") }
        return "subprocess produced no verdict" unless line

        verdict = JSON.parse(line)
        return nil if verdict["ok"]

        verdict["error"].to_s
      rescue StandardError
        "subprocess produced unreadable output"
      end
    end
  end
end
