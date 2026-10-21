# frozen_string_literal: true

require "open3"
require "timeout"

module Rubik
  module Platform
    # Process and environment management (e.g. kill_tree, popen_capture).
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Process
      def self.included(base)
        base.extend self
      end

      # Execute a command via Open3.popen3 with timeout, concurrent stream reads,
      # signal exit status mapping, and automatic process-tree termination on timeout.
      def popen_capture(*, timeout: 15, chdir: Dir.pwd, timeout_message: nil, error_message: nil)
        start_time = Time.now
        stdout_str = ""
        stderr_str = ""
        exit_code = 127
        pid = nil

        begin
          Timeout.timeout(timeout) do
            Open3.popen3(*, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
              pid = wait_thr.pid if wait_thr.respond_to?(:pid)
              begin
                stdin.close
              rescue StandardError
                nil
              end
              t_out = Thread.new do
                stdout.read
              rescue StandardError
                ""
              end
              t_err = Thread.new do
                stderr.read
              rescue StandardError
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
                rescue StandardError
                  nil
                end
                begin
                  t_err.kill
                rescue StandardError
                  nil
                end
              end
            end
          end
        rescue Timeout::Error
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
          pid: pid
        }
      end

      def kill_tree(pid)
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
          # On Unix/Linux, collect descendant PIDs so child processes are not
          # orphaned when the parent process is killed.
          descendants = descendant_pids(pid)
          descendants.each do |cpid|
            begin
              ::Process.kill("TERM", cpid)
            rescue StandardError
              nil
            end
            begin
              ::Process.kill("KILL", cpid)
            rescue StandardError
              nil
            end
          end
          begin
            ::Process.kill("TERM", pid)
          rescue StandardError
            nil
          end
          begin
            ::Process.kill("KILL", pid)
          rescue StandardError
            nil
          end
        end
      end

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

      private

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

        out = begin
          `pgrep -P #{pid} 2>/dev/null`
        rescue StandardError
          nil
        end
        return out.lines.map(&:to_i).reject(&:zero?) if out && !out.empty?

        out = begin
          `ps --ppid #{pid} -o pid= 2>/dev/null`
        rescue StandardError
          nil
        end
        return out.lines.map(&:to_i).reject(&:zero?) if out && !out.empty?

        []
      rescue StandardError
        []
      end

      extend self
    end
  end
end
