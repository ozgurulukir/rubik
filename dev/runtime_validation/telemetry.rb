# frozen_string_literal: true

require "rbconfig"

module Rubik
  module RuntimeValidation
    # Telemetry and resource monitoring for runtime validation.
    # Measures threads, child processes, file descriptors, memory (RSS), and GC heap.
    module Telemetry
      class << self
        def snapshot
          GC.start
          begin
            GC.compact
          rescue StandardError
            nil
          end
          pid = Process.pid
          {
            threads: active_user_thread_count,
            child_processes: active_child_process_count(pid),
            open_fds: probe_open_fds(pid),
            rss_kb: probe_rss_kb(pid),
            heap_live_slots: GC.stat[:heap_live_slots]
          }
        end

        def active_user_thread_count
          Thread.list.count do |th|
            th.alive? &&
              (!th.name || !th.name.include?("Timeout stdlib thread")) &&
              !th.inspect.include?("timeout.rb")
          end
        end

        def system_info
          {
            ruby_version: RUBY_VERSION,
            ruby_patchlevel: RUBY_PATCHLEVEL,
            ruby_platform: RUBY_PLATFORM,
            host_os: RbConfig::CONFIG["host_os"],
            cpu_arch: RbConfig::CONFIG["host_cpu"],
            capabilities: probe_capabilities
          }
        end

        def active_child_process_count(pid)
          children = begin
            Rubik::Platform.descendant_pids(pid)
          rescue StandardError
            []
          end
          children.count do |cpid|
            system("kill -0 #{cpid} 2>/dev/null")
          end
        rescue StandardError
          0
        end

        def probe_open_fds(pid)
          fd_dir = "/proc/#{pid}/fd"
          return nil unless File.directory?(fd_dir)

          Dir.glob("#{fd_dir}/*").count
        rescue StandardError
          nil
        end

        def probe_rss_kb(pid)
          status_file = "/proc/#{pid}/status"
          return nil unless File.exist?(status_file)

          content = File.read(status_file)
          match = content[/VmRSS:\s+(\d+)\s+kB/, 1]
          match&.to_i
        rescue StandardError
          nil
        end

        def probe_capabilities
          socket_ok = begin
            s = TCPServer.new("127.0.0.1", 0)
            s.close
            true
          rescue StandardError
            false
          end

          proc_ok = File.directory?("/proc/#{Process.pid}")
          {
            sockets: socket_ok,
            proc_filesystem: proc_ok,
            process_tree: Rubik::Platform.unix? || Rubik::Platform.windows?
          }
        end

        def anonymize_path(path)
          return "" unless path

          path.to_s
              .gsub(Dir.home, "<home>")
              .gsub(Dir.pwd, "<repo>")
              .gsub(%r{home/[^/]+}, "home/<user>")
        end
      end
    end
  end
end
