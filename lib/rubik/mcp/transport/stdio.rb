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
          @mutex = Mutex.new
          @cv = ConditionVariable.new
          @responses = {}
        end

        def open
          return if @running

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

          @running = true
          @req_id = 0
          @responses.clear

          start_reader_thread
          self
        end
        alias start open

        def send_request(method, params = {}, timeout: 10)
          raise ConnectionError, "MCP transport is not running" unless @running && @stdin

          req_id = @mutex.synchronize do
            @req_id += 1
            @req_id
          end

          msg = {
            "jsonrpc" => "2.0",
            "id" => req_id,
            "method" => method.to_s,
            "params" => params || {}
          }

          write_message(msg)
          wait_for_response(req_id, timeout: timeout)
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
          return unless @running || @wait_thr&.alive?

          @running = false

          begin
            @reader_thr&.kill
          rescue StandardError
            nil
          end

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

          if @wait_thr&.alive?
            Rubik::Platform.kill_tree(@wait_thr.pid)
            begin
              @wait_thr.join(0.5)
            rescue StandardError
              nil
            end
          end
          @wait_thr = nil

          @mutex.synchronize do
            @responses.clear
            @cv.broadcast
          end
        end
        alias stop close
        alias dispose close

        def running?
          @running && (@wait_thr.nil? || @wait_thr.alive?)
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
                raise TimeoutError, "Timed out waiting for MCP response to request #{req_id} after #{timeout}s"
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
          @reader_thr = Thread.new do
            while @running && @stdout && !@stdout.closed?
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
              @running = false
              @cv.broadcast
            end
          end
        end

        def handle_incoming_message(msg)
          return unless msg.is_a?(Hash) && msg.key?("id")

          @mutex.synchronize do
            @responses[msg["id"]] = msg
            @cv.broadcast
          end
        end
      end
    end
  end
end
