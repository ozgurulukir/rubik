# frozen_string_literal: true

require "open3"
require "json"
require "shellwords"
require_relative "../errors"
require_relative "../../platform"
require_relative "../../security/guard"

module Rubik
  module MCP
    module Transport
      class Stdio
        # The child's stderr pipe is drained continuously (see
        # #start_stderr_thread); this many recent lines stay queryable via
        # #stderr_tail for diagnostics.
        STDERR_TAIL_LINES = 20

        attr_reader :command, :args, :env, :root_dir, :running, :wait_thr

        def initialize(command, args: [], env: {}, root_dir: Dir.pwd, guard: nil)
          @command = command
          @args = Array(args).map(&:to_s)
          @env = env || {}
          @root_dir = File.expand_path(root_dir)
          @guard = guard || Rubik::Security::Guard.new
          @running = false
          @req_id = 0
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thr = nil
          @reader_thr = nil
          @stderr_thr = nil
          @stderr_mutex = Mutex.new
          @stderr_tail = []
          @mutex = Mutex.new
          @cv = ConditionVariable.new
          @responses = {}
          @closed = false
          @generation = 0
          @pending_requests = Set.new
        end

        def open
          return if running?

          # A previous incarnation whose child died on its own (the reader's
          # ensure cleared @running) still holds pipe FDs and an unreaped
          # wait thread; re-spawning over them leaks both. close is
          # idempotent and a no-op when nothing lingers.
          close if @wait_thr || @reader_thr || @stderr_thr

          cmd_parts = if @args.empty? && @command.is_a?(String)
                        begin
                          Shellwords.split(@command)
                        rescue ArgumentError => e
                          raise ConnectionError, "Invalid command syntax: #{e.message}"
                        end
                      else
                        [@command.to_s] + @args
                      end

          bin = cmd_parts.first
          raise ConnectionError, "MCP command cannot be empty" if bin.nil? || bin.empty?

          # Red-Team Defense: Verify command safety against destructive operations.
          # Route the MCP spawn command through the same Guard#verify_command_safety!
          # call that RunCommandTool uses — the narrow DANGEROUS_COMMAND_PATTERNS
          # subset below was a bypass: it misses many dangerous commands the
          # classifier flags. Fails closed on any dangerous/unmanaged command.
          full_cmd = Shellwords.shelljoin(cmd_parts)
          begin
            @guard.verify_command_safety!(full_cmd)
          rescue Rubik::Security::BlockedWriteError => e
            # No manual audit here: verify_command_safety! already logged
            # "blocked_command" with the TRUE classifier reason before raising
            # — a second hardcoded entry would double-log and mislabel it.
            raise ConnectionError, "Security blocked MCP process: #{e.message}"
          end

          resolved_bin = Rubik::Platform.which(bin)
          cmd_parts[0] = resolved_bin if resolved_bin

          string_env = @env.transform_keys(&:to_s).transform_values(&:to_s)

          begin
            @stdin, @stdout, @stderr, @wait_thr = if string_env.empty?
                                                    Open3.popen3(*cmd_parts, chdir: @root_dir)
                                                  else
                                                    Open3.popen3(string_env, *cmd_parts, chdir: @root_dir)
                                                  end
          rescue SystemCallError => e
            raise ConnectionError, "Failed to spawn MCP process '#{bin}': #{e.message}"
          end

          @mutex.synchronize do
            @running = true
            @closed = false
            @generation += 1
            @req_id = 0
            @responses.clear
            @pending_requests.clear
          end
          @stderr_mutex.synchronize { @stderr_tail.clear }

          start_stderr_thread
          start_reader_thread
          self
        end
        alias start open

        def send_request(method, params = {}, timeout: 10)
          raise ConnectionError, "MCP transport is not running" unless running? && @stdin

          req_id = @mutex.synchronize do
            @req_id += 1
            @pending_requests.add(@req_id)
            @pending_requests.add(@req_id.to_s)
            @req_id
          end

          msg = {
            "jsonrpc" => "2.0",
            "id" => req_id,
            "method" => method.to_s,
            "params" => params || {}
          }

          begin
            write_message(msg)
            wait_for_response(req_id, timeout: timeout)
          ensure
            @mutex.synchronize do
              @pending_requests.delete(req_id)
              @pending_requests.delete(req_id.to_s)
              @responses.delete(req_id)
              @responses.delete(req_id.to_s)
            end
          end
        end

        def send_notification(method, params = {})
          raise ConnectionError, "MCP transport is not running" unless @running && @stdin

          msg = {
            "jsonrpc" => "2.0",
            "method" => method.to_s,
            "params" => params || {}
          }

          write_message(msg)
        end

        def close
          child_died = false
          @mutex.synchronize do
            return if @closed

            child_died = !@running
            @closed = true
            @running = false
          end

          begin
            @reader_thr&.kill
          rescue StandardError
            nil
          end

          begin
            @stderr_thr&.kill
          rescue StandardError
            nil
          end

          if @wait_thr&.alive?
            pid_to_kill = @wait_thr.pid
            Rubik::Platform.kill_tree(pid_to_kill)
            begin
              @wait_thr.join(0.5)
            rescue StandardError
              nil
            end

            if @wait_thr.alive?
              abandoned_waiter = @wait_thr
              Thread.new do
                begin
                  abandoned_waiter.join(2.5)
                rescue StandardError
                  nil
                end
                Rubik::Log.warn(:mcp, "abandoned child process pid #{pid_to_kill} did not exit within reaper window") if abandoned_waiter.alive?
              end
            end
          end
          @wait_thr = nil

          [@stdin, @stdout, @stderr].each do |io|
            io&.close unless io&.closed?
          rescue StandardError
            nil
          end

          begin
            @reader_thr&.join(0.5)
          rescue StandardError
            nil
          ensure
            @reader_thr = nil
          end

          begin
            @stderr_thr&.join(0.5)
          rescue StandardError
            nil
          ensure
            @stderr_thr = nil
          end

          if child_died
            hint = stderr_tail.last(5).join(" | ")[0, 512]
            Rubik::Log.warn(:mcp, "MCP child process (pid #{pid}) had already exited; recent stderr: #{hint}") unless hint.empty?
          end

          @mutex.synchronize do
            @responses.clear
            @pending_requests.clear
            @cv.broadcast
          end
        end
        alias stop close
        alias dispose close

        def running?
          @mutex.synchronize do
            @running && (@wait_thr.nil? || @wait_thr.alive?)
          end
        end

        # Recent stderr output from the child (last STDERR_TAIL_LINES lines).
        # The drain keeps the OS pipe buffer empty so a chatty server can
        # never block on stderr write; the tail is what makes that output
        # diagnosable instead of silently discarded.
        def stderr_tail
          @stderr_mutex.synchronize { @stderr_tail.dup }
        end

        def pid
          @wait_thr&.pid
        end

        private

        def write_message(msg_hash)
          json = JSON.dump(msg_hash)
          @mutex.synchronize do
            raise ConnectionError, "Process stdin is closed" if @stdin.nil? || @stdin.closed?

            @stdin.puts(json)
            @stdin.flush
          end
        rescue IOError, Errno::EPIPE => e
          close
          raise ConnectionError, "Failed to write to MCP server: #{e.message}"
        end

        def wait_for_response(req_id, timeout: 10)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = @mutex.synchronize do
            loop do
              match = @responses.delete(req_id) || @responses.delete(req_id.to_s) || @responses.delete(req_id.to_i)
              break match if match
              raise ConnectionError, "MCP transport stopped while waiting for response" unless @running

              elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
              remaining = timeout - elapsed
              if remaining <= 0
                @responses.delete(req_id)
                # The stderr tail is the one place a wedged server explains
                # itself (crash traces, logging storms); attach it so the
                # timeout is diagnosable instead of opaque.
                hint = stderr_tail.last(3).join(" | ")[0, 512]
                suffix = hint.empty? ? "" : "; server stderr: #{hint}"
                raise TimeoutError, "Timed out waiting for MCP response to request #{req_id} after #{timeout}s#{suffix}"
              end

              @cv.wait(@mutex, remaining)
            end
          end

          if response["error"]
            err = response["error"]
            code = err.is_a?(Hash) ? err["code"] : nil
            msg = err.is_a?(Hash) ? (err["message"] || err.to_s) : err.to_s
            code_str = code ? " (#{code})" : ""
            raise ProtocolError, "MCP error#{code_str}: #{msg}"
          end

          response["result"]
        end

        def start_reader_thread
          gen = @mutex.synchronize { @generation }
          @reader_thr = Thread.new do
            while @mutex.synchronize { @running } && @stdout && !@stdout.closed?
              line = begin
                @stdout.gets
              rescue IOError, Errno::EBADF
                nil
              end
              break unless line

              line = line.strip
              next if line.empty?

              begin
                msg = JSON.parse(line)
                handle_incoming_message(msg)
              rescue JSON::ParserError
                # Ignore non-JSON server logs, keep reader alive
              end
            end
          ensure
            @mutex.synchronize do
              if @generation == gen
                @running = false
                @cv.broadcast
              end
            end
          end
        end

        # Drain the child's stderr on its own thread. Without a reader, a
        # server that logs more than the OS pipe buffer holds (~64KB on
        # Linux, far less on Windows) blocks inside its write() and stops
        # answering requests — every call then times out with no hint that
        # the child is wedged on its own logging. EOF on stderr must NOT
        # stop the transport: a child may close stderr and keep serving.
        def start_stderr_thread
          @stderr_thr = Thread.new do
            while @running && @stderr && !@stderr.closed?
              line = begin
                @stderr.gets
              rescue IOError, Errno::EBADF
                nil
              end
              break unless line

              line = line.chomp
              # Cap retained size per line: a newline-less flood must not
              # turn the diagnostic tail into a memory hog.
              line = line[0, 4096] if line.length > 4096

              @stderr_mutex.synchronize do
                @stderr_tail << line
                @stderr_tail.shift while @stderr_tail.length > STDERR_TAIL_LINES
              end
            end
          rescue IOError, Errno::EBADF
            nil
          rescue StandardError => e
            # A silently dead drainer would recreate the exact wedge this
            # thread exists to prevent — make its death greppable.
            Rubik::Log.warn(:mcp, "stderr drain thread exited unexpectedly (#{e.class}: #{e.message}); the MCP child may block on a full stderr pipe")
          end
        end

        def handle_incoming_message(msg)
          return unless msg.is_a?(Hash) && msg.key?("id")

          @mutex.synchronize do
            return unless @pending_requests.include?(msg["id"])

            @responses[msg["id"]] = msg
            @cv.broadcast
          end
        end
      end
    end
  end
end
