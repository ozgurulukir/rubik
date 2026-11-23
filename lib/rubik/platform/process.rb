# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "../log"

module Rubik
  module Platform
    # Process and environment management (e.g. kill_tree, popen_capture).
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Process
      def self.included(base)
        base.extend self
      end

      # Default swallowed-IO-error observer for the popen3 drain core
      # (issue #444): reader-thread deaths are now visible via Log.debug
      # (adopting the adapter variant's log-on-swallow behavior) instead of
      # being swallowed silently, while stdin-close and reader-thread kill
      # failures stay silent teardown noise, as before. Log is error-isolated,
      # so the observer itself can never raise.
      DEFAULT_ON_IO_ERROR = lambda do |event, error|
        case event
        when :stdout_read
          Rubik::Log.debug(:platform, "stdout read failed during process execution: #{error.class}: #{error.message}")
        when :stderr_read
          Rubik::Log.debug(:platform, "stderr read failed during process execution: #{error.class}: #{error.message}")
        end
      end

      # Single-homed popen3 + dual reader-thread drain core (issue #444):
      # executes a command via Open3.popen3 with timeout, concurrent
      # stdout/stderr drain (prevents the OS pipe buffer from filling and
      # deadlocking the child), signal exit status mapping, and automatic
      # process-tree termination on timeout. Consumers: sandbox drivers and
      # Rubik::Adapter::ProcessRunner, which overrides on_io_error to keep
      # its legacy Log.debug(:adapter) trace of every swallowed IO error.
      #
      # on_io_error is invoked as (event, exception) for each IO error the
      # core must swallow to keep draining: :stdin_close, :stdout_read,
      # :stderr_read, :stdout_kill, :stderr_kill. For long-lived
      # line-oriented drains (LSP stderr) use Platform::IoDrain instead;
      # this core is the synchronous capture-to-string variant.
      def popen_capture(*, timeout: 15, chdir: Dir.pwd, timeout_message: nil, error_message: nil, on_io_error: nil)
        on_io_error ||= DEFAULT_ON_IO_ERROR
        start_time = Time.now
        stdout_str = ""
        stderr_str = ""
        exit_code = 127
        pid = nil
        watchdog = nil
        deadline_hit = false
        timed_out = false

        begin
          Open3.popen3(*, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
            pid = wait_thr.pid if wait_thr.respond_to?(:pid)
            # Deadline watchdog (issue #479): kill the tree from a separate
            # thread the moment the deadline fires, so a hung child never
            # outlives `timeout`. The kill must NOT ride Timeout.timeout's
            # timer thread: its unwind races the kill, and if the unwind wins,
            # popen3's ensure joins the still-running child and the timeout
            # merely relabels the result instead of bounding the wall clock.
            # Instead the watchdog kills first and sets deadline_hit, and the
            # Timeout::Error is raised only after the block has returned.
            # Cancelled in the inner ensure to keep the watchdog from firing
            # into a recycled pid after normal exit.
            watchdog = Thread.new(pid, timeout.to_f) do |w_pid, w_deadline|
              # Snapshot identity BEFORE the sleep: if the child exits and its
              # PID is recycled while we wait, the captured starttime no longer
              # matches and kill_tree refuses to signal the new process.
              identity = process_identity(w_pid)
              slept = false
              begin
                sleep w_deadline
                slept = true
                # Race guard (issue #597): only flag a timeout when the kill
                # actually targets a still-live process — a child that completes
                # exactly as the deadline fires keeps its real exit status
                # instead of being relabeled exit 124.
                deadline_hit = true if process_alive?(w_pid)
                kill_tree(w_pid, identity: identity)
              rescue StandardError => e
                # Issue #597-2 follow-up: a kill-path failure at the deadline
                # must never silently drop the timeout — the deadline has
                # fired, so mark it (the caller below raises Timeout::Error
                # and still attempts its own kill) and log the failure.
                # `slept` guards against a spurious mark if the thread itself
                # dies before the deadline. Thread#kill lands as an
                # uncatchable KillError, so a normal-exit cancellation never
                # reaches this rescue.
                if slept
                  deadline_hit = true
                  Rubik::Log.warn(:platform, "popen_capture deadline kill failed for pid #{w_pid}: " \
                                             "#{e.class}: #{e.message}")
                end
              end
            end
            begin
              stdin.close
            rescue StandardError => e
              on_io_error.call(:stdin_close, e)
            end
            t_out = Thread.new do
              stdout.read
            rescue StandardError => e
              on_io_error.call(:stdout_read, e)
              ""
            end
            t_err = Thread.new do
              stderr.read
            rescue StandardError => e
              on_io_error.call(:stderr_read, e)
              ""
            end
            begin
              stdout_str = t_out.value.to_s
              stderr_str = t_err.value.to_s
              status = wait_thr.value
              exit_code = status.exitstatus || (status.signaled? ? (128 + (status.termsig || 1)) : 1)
            ensure
              begin
                watchdog&.kill
              rescue StandardError
                nil
              end
              begin
                t_out.kill
              rescue StandardError => e
                on_io_error.call(:stdout_kill, e)
              end
              begin
                t_err.kill
              rescue StandardError => e
                on_io_error.call(:stderr_kill, e)
              end
            end
          end
          raise Timeout::Error, "execution expired" if deadline_hit
        rescue Timeout::Error
          timed_out = true
          kill_tree(pid) if pid
          stderr_str = timeout_message || "Execution timed out after #{timeout} seconds"
          exit_code = 124
        rescue Errno::ENOENT => e
          stderr_str = "Binary not found: #{e.message}"
          exit_code = 127
        rescue StandardError => e
          msg_prefix = error_message ? "#{error_message}: " : "Execution error: "
          stderr_str = "#{msg_prefix}#{e.message}"
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
          pid: pid,
          # Explicit timeout flag (issue #597): exit code 124 is also a
          # legitimate exit code of timeout(1) and other workloads, so the
          # tool layer must not re-derive `timed_out` from the exit code.
          timed_out: timed_out || deadline_hit
        }
      end

      def kill_tree(pid, identity: nil)
        return unless pid&.positive?

        if windows?
          begin
            # Plan 55 D-1 ile tutarlı dizi-form çağrı: cmd.exe ara katmanı ve kabuk
            # yönlendirmesi ("> NUL 2>&1") yerine out:/err: seçenekleri kullanılır.
            system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
          rescue StandardError
            nil
          end
        else
          # PID reuse guard: the deadline watchdog snapshots this identity
          # before sleeping. A mismatch means the PID now names a different
          # process — signal nothing rather than kill an unrelated process.
          expected = identity || process_identity(pid)
          return unless identity_unchanged?(pid, expected)

          # On Unix/Linux, collect descendant PIDs so child processes are not
          # orphaned when the parent process is killed. TERM gets a short
          # grace window before KILL escalates: back-to-back TERM→KILL gave
          # graceful shutdown no scheduling window, so lock/file/socket
          # holders were always hard-killed.
          targets = (descendant_pids(pid) + [pid]).uniq
          identities = targets.to_h { |tpid| [tpid, process_identity(tpid)] }
          signal_all(targets, "TERM", identities)

          # Escalate to KILL for whatever is still alive once the grace
          # window lapses (or the loop observes all targets gone early).
          # ::Process, not Process: this file defines Rubik::Platform::Process,
          # which would otherwise shadow the top-level constant.
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + KILL_TREE_GRACE_SECONDS
          still_alive = targets
          until ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
            still_alive = targets.select { |tpid| process_alive?(tpid) && identity_unchanged?(tpid, identities[tpid]) }
            break if still_alive.empty?

            sleep 0.01
          end
          signal_all(still_alive, "KILL", identities)
        end
      end

      KILL_TREE_GRACE_SECONDS = 0.2

      # PATH-resolved process helpers are a trust boundary: a poisoned PATH
      # could make `pgrep`/`ps` print attacker-chosen PIDs into the kill list.
      # The /proc path below is primary; these absolute locations are the only
      # fallback, and every capture is deadline-bounded.
      HELPER_LOCATIONS = {
        "pgrep" => ["/usr/bin/pgrep", "/bin/pgrep", "/usr/sbin/pgrep", "/sbin/pgrep"],
        "ps" => ["/usr/bin/ps", "/bin/ps", "/usr/sbin/ps", "/sbin/ps"]
      }.freeze
      HELPER_CAPTURE_TIMEOUT_SECONDS = 0.5

      # Collect all descendant process IDs recursively (leaves first).
      def descendant_pids(pid)
        return [] unless pid&.positive?

        collected = []
        queue = [pid]
        until queue.empty?
          curr = queue.shift
          children = direct_child_pids(curr)
          children.each do |cpid|
            next if collected.include?(cpid) || cpid == pid

            collected << cpid
            queue << cpid
          end
        end
        collected.reverse
      rescue StandardError
        []
      end

      # Deadline-bounded write to a (possibly blocking) pipe: converts a
      # never-draining reader — a child that stopped reading stdin — into an
      # Errno::EPIPE raise after `timeout` seconds instead of parking the
      # caller forever on a full OS pipe buffer. Uses write_nonblock + wait,
      # so the fd's blocking flag is irrelevant. Exposed via Rubik::Platform.
      def write_until(io, text, timeout: 5.0)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout.to_f
        text = text.to_s
        until text.empty?
          written = io.write_nonblock(text, exception: false)
          case written
          when :wait_writable
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            raise Errno::EPIPE, "pipe write exceeded #{timeout}s deadline" if remaining <= 0

            io.wait_writable(remaining) or raise Errno::EPIPE, "pipe write exceeded #{timeout}s deadline"
          when Integer
            text = text.byteslice(written..)
          end
        end
        nil
      end

      private

      def signal_all(pids, sig, identities = {})
        pids.each do |tpid|
          # Last-moment re-check: a PID recycled after the grace window must
          # never receive a signal meant for the original child.
          next unless identity_unchanged?(tpid, identities[tpid])

          ::Process.kill(sig, tpid)
        rescue StandardError
          nil
        end
      end

      def process_alive?(pid)
        ::Process.kill(0, pid)
        true
      rescue StandardError
        false
      end

      # /proc/<pid>/stat field 22 (starttime) is fixed for a process's whole
      # lifetime, so it distinguishes the original child from a recycled PID.
      # nil (no /proc, or an already-reaped pid) means there is no identity to
      # compare — the liveness check remains the best available guard.
      def process_identity(pid)
        return nil unless pid&.positive?

        stat = File.read("/proc/#{pid}/stat")
        stat.rpartition(")")[2].to_s.split[19]
      rescue StandardError
        nil
      end

      def identity_unchanged?(pid, identity)
        identity.nil? || process_identity(pid) == identity
      end

      # Never resolve a process helper through PATH: a poisoned PATH would let
      # a fake `pgrep` inject arbitrary PIDs into the kill list. Only known
      # absolute locations are eligible, and each capture is bounded so a
      # hung helper cannot stall teardown.
      def capture_helper(name, *)
        helper = HELPER_LOCATIONS.fetch(name, []).find { |path| File.executable?(path) }
        return nil unless helper

        Timeout.timeout(HELPER_CAPTURE_TIMEOUT_SECONDS) do
          out, = Open3.capture2(helper, *, err: File::NULL)
          out
        end
      rescue StandardError
        nil
      end

      def direct_child_pids(pid)
        task_dir = "/proc/#{pid}/task"
        if File.directory?(task_dir)
          pids = []
          Dir.glob("#{task_dir}/*/children").each do |path|
            content = begin
              File.read(path)
            rescue StandardError
              nil
            end
            pids.concat(content.split.map(&:to_i)) if content
          end
          return pids.reject(&:zero?) unless pids.empty?
        end

        out = capture_helper("pgrep", "-P", pid.to_s)
        return out.lines.map(&:to_i).reject(&:zero?) if out && !out.empty?

        out = capture_helper("ps", "--ppid", pid.to_s, "-o", "pid=")
        return out.lines.map(&:to_i).reject(&:zero?) if out && !out.empty?

        []
      rescue StandardError
        []
      end

      extend self
    end
  end
end
