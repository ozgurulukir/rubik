# frozen_string_literal: true

require "reline"

module Rubik
  module REPL
    # Encapsulates Ctrl+C (SIGINT) handling for the interactive REPL loop.
    #
    # On Windows, Reline's default interrupt behavior can leave the line editor
    # in a wedged state after a Ctrl+C: the next prompt neither echoes input nor
    # honors EOF (Ctrl+D / Ctrl+Z), so the REPL appears frozen and cannot be
    # exited. This module installs a SIGINT handler that raises Interrupt (so a
    # running command -- orchestrator loop, HTTP call -- aborts promptly and
    # Reline's own teardown restores console mode) and provides a best-effort
    # line-editor reset to recover an unresponsive prompt.
    module InterruptHandler
      # Install a SIGINT handler that raises Interrupt, returning the previous
      # handler so the caller can restore it on exit. Reline captures this trap
      # as its @old_trap and calls it, so the Interrupt propagates out of
      # Reline.readline cleanly.
      def self.install
        Signal.trap("INT") { raise Interrupt }
      end

      # Restore a previously captured SIGINT handler (value from .install).
      def self.restore(prev_handler)
        Signal.trap("INT", prev_handler) if prev_handler
      end

      # Run a block with the Interrupt-raising SIGINT handler installed, always
      # restoring the previous handler and the console afterwards. Usage:
      #   Rubik::REPL::InterruptHandler.with_handler { ... loop body ... }
      def self.with_handler
        prev = install
        yield
      ensure
        restore(prev)
        restore_console_after_interrupt
      end

      # Best-effort reset of Reline's line editor and console state after an interrupt.
      # On Windows, an interrupted/aborted readline or external command execution can
      # leave the line editor with dirty input buffers or stale console handles.
      # Resetting the editor drops any half-entered buffer, clears IOGate input/output
      # buffers, flushes console input, and refreshes standard handles.
      def self.restore_console_after_interrupt
        return unless defined?(Reline)

        if Reline.respond_to?(:line_editor) && (le = Reline.line_editor)
          begin
            if le.respond_to?(:reset)
              # reline's released signature varies across versions (reset(prompt='', encoding: ...) vs reset(prompt=''))
              begin
                enc = (Reline.respond_to?(:encoding_system) ? Reline.encoding_system : Encoding.default_external)
                le.reset("", encoding: enc)
              rescue ArgumentError
                begin
                  le.reset("")
                rescue ArgumentError
                  le.reset
                end
              end
            elsif le.respond_to?(:reset_line)
              le.reset_line
            end
          rescue StandardError
            nil
          end
        end

        if defined?(Reline::IOGate) && (io = Reline::IOGate)
          # Clear internal buffers so unconsumed control characters/interrupt bytes don't bleed into next prompt
          begin
            if io.instance_variable_defined?(:@output_buf) && (buf = io.instance_variable_get(:@output_buf)).is_a?(Array)
              buf.clear
            end
            if io.instance_variable_defined?(:@input_buf) && (buf = io.instance_variable_get(:@input_buf)).is_a?(Array)
              buf.clear
            end
            io.instance_variable_set(:@hsg, nil) if io.instance_variable_defined?(:@hsg)
          rescue StandardError
            nil
          end

          # Refresh Windows console handles and flush console buffer if on Windows
          begin
            if io.is_a?(Reline::Windows) || (defined?(Reline::Windows) && io.class.name.to_s.include?("Windows"))
              get_std_handle = io.instance_variable_get(:@GetStdHandle)
              if get_std_handle
                new_in = begin
                  get_std_handle.call(Reline::Windows::STD_INPUT_HANDLE)
                rescue
                  nil
                end
                io.instance_variable_set(:@hConsoleInputHandle, new_in) if new_in && new_in != 0

                new_out = begin
                  get_std_handle.call(Reline::Windows::STD_OUTPUT_HANDLE)
                rescue
                  nil
                end
                io.instance_variable_set(:@hConsoleHandle, new_out) if new_out && new_out != 0

                if new_in && new_in != 0 && defined?(Reline::Windows::Win32API)
                  flush_func = io.instance_variable_get(:@FlushConsoleInputBuffer) ||
                               begin
                                 Reline::Windows::Win32API.new("kernel32", "FlushConsoleInputBuffer", ["L"], "I")
                               rescue
                                 nil
                               end
                  if flush_func
                    io.instance_variable_set(:@FlushConsoleInputBuffer, flush_func)
                    begin
                      flush_func.call(new_in)
                    rescue
                      nil
                    end
                  end
                end
              end
            end
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        nil
      end
    end
  end
end

# Windows Reline Self-Healing Console Input Patch:
# If external commands or process interruptions invalidate @hConsoleInputHandle,
# prevent Reline::Windows#check_input_event from entering an infinite spin loop
# by refreshing the console input handle on WAIT_FAILED (-1 / 0xFFFFFFFF).
if defined?(Reline::Windows)
  class Reline::Windows
    unless method_defined?(:rubik_original_check_input_event)
      alias rubik_original_check_input_event check_input_event

      def check_input_event
        if @hConsoleInputHandle.nil? || @hConsoleInputHandle.zero? || @hConsoleInputHandle == -1
          @hConsoleInputHandle = begin
            @GetStdHandle.call(STD_INPUT_HANDLE)
          rescue
            nil
          end
        end

        num_of_events = 0.chr * 8
        while @output_buf.empty?
          Reline.core.line_editor.handle_signal
          wait_res = @WaitForSingleObject.call(@hConsoleInputHandle, 100)
          if wait_res != 0
            if [0xFFFFFFFF, 4_294_967_295, -1].include?(wait_res)
              @hConsoleInputHandle = begin
                @GetStdHandle.call(STD_INPUT_HANDLE)
              rescue
                nil
              end
              @hConsoleHandle = begin
                @GetStdHandle.call(STD_OUTPUT_HANDLE)
              rescue
                nil
              end
            end
            @legacy_console = begin
              (getconsolemode & ENABLE_VIRTUAL_TERMINAL_PROCESSING).zero?
            rescue
              false
            end
            next
          end
          if @GetNumberOfConsoleInputEvents.call(@hConsoleInputHandle, num_of_events).zero? || num_of_events.unpack1("L").zero?
            @hConsoleInputHandle = begin
              @GetStdHandle.call(STD_INPUT_HANDLE)
            rescue
              nil
            end
            next
          end
          input_records = 0.chr * 20 * 80
          read_event = 0.chr * 4
          if @ReadConsoleInputW.call(@hConsoleInputHandle, input_records, 80, read_event).zero?
            @hConsoleInputHandle = begin
              @GetStdHandle.call(STD_INPUT_HANDLE)
            rescue
              nil
            end
          else
            read_events = read_event.unpack1("L") || 0
            read_events.times do |idx|
              input_record = input_records[idx * 20, 20]
              next unless input_record && input_record.bytesize >= 20

              event = input_record[0, 2].unpack1("s*")
              case event
              when WINDOW_BUFFER_SIZE_EVENT
                @winch_handler&.call
              when KEY_EVENT
                key_down = input_record[4, 4].unpack1("l*")
                repeat_count = input_record[8, 2].unpack1("s*")
                virtual_key_code = input_record[10, 2].unpack1("s*")
                virtual_scan_code = input_record[12, 2].unpack1("s*")
                char_code = input_record[14, 2].unpack1("S*")
                control_key_state = input_record[16, 2].unpack1("S*")
                is_key_down = !key_down.zero?
                process_key_event(repeat_count, virtual_key_code, virtual_scan_code, char_code, control_key_state) if is_key_down
              end
            end
          end
        end
      end
    end
  end
end
