# frozen_string_literal: true

module Rubik
  module Platform
    # Process and environment management (e.g. kill_tree).
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Process
      def self.included(base)
        base.extend self
      end

      def kill_tree(pid)
        return unless pid&.positive?

        if windows?
          begin
            # Plan 55 D-1 ile tutarlı dizi-form çağrı: cmd.exe ara katmanı ve kabuk
            # yönlendirmesi ("> NUL 2>&1") yerine out:/err: seçenekleri kullanılır.
            system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
          rescue
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
    end
  end
end
