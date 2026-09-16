# frozen_string_literal: true

module Rubik
  module REPL
    # Öneri 3 (Kademe 1): Shell'den ayrılan girdi döngüsü sorumluluğu.
    # Hem interaktif (Reline) hem stream (pipeline) koşumunun satır düzeyi
    # ayrıştırması: çoklu-satır tamponu, heredoc modu ve EOF/^C davranışı.
    # Durum Shell'de yaşar (@running, @reline, @input, @output); bu modül
    # yalnızca döngü politikasını kodlar.
    module InputLoop
      def run_stream(stream)
        stream.each_line do |line|
          break unless @running

          process_multiline_or_line(line.chomp)
        end
      end

      def run_interactive
        @running = true
        multiline_buffer = []
        heredoc_delimiter = nil
        print_banner
        Rubik::REPL::InterruptHandler.with_handler do
          while @running
            result = read_and_process_line(multiline_buffer, heredoc_delimiter)
            break if result[:stop]

            multiline_buffer = result[:buffer]
            heredoc_delimiter = result[:delimiter]
          end
        end
      ensure
        stop
      end

      # Processes one line of interactive input. Returns a hash with:
      #   stop:      true if the REPL should exit
      #   buffer:    updated multiline buffer
      #   delimiter: updated heredoc delimiter (nil if not in heredoc mode)
      def read_and_process_line(multiline_buffer, heredoc_delimiter)
        current_prompt, boxed = prepare_prompt_line(!heredoc_delimiter.nil?)
        line = @reline.readline(current_prompt, false)
        @output.puts box_bottom_border if boxed
        return handle_eof(multiline_buffer, heredoc_delimiter) if line.nil? || line == "\x04" || line == "\x1a"

        # Push non-empty command to history
        @reline::HISTORY.push(line) if !line.strip.empty? && line != begin
          @reline::HISTORY.to_a.last
        rescue
          nil
        end

        if heredoc_delimiter
          process_heredoc_line(line, multiline_buffer, heredoc_delimiter)
        else
          process_normal_line(line, multiline_buffer)
        end
      rescue Interrupt
        @output.puts "^C"
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        { stop: false, buffer: [], delimiter: nil }
      rescue StandardError => e
        @output.puts "[REPL Error] #{e.class}: #{e.message}"
        { stop: false, buffer: [], delimiter: nil }
      end

      def handle_eof(multiline_buffer, heredoc_delimiter)
        if heredoc_delimiter
          @output.puts "\n[Rubik] Multiline input cancelled."
          { stop: false, buffer: [], delimiter: nil }
        else
          stop
          { stop: true, buffer: multiline_buffer, delimiter: heredoc_delimiter }
        end
      end

      def process_heredoc_line(line, multiline_buffer, heredoc_delimiter)
        if line.strip == heredoc_delimiter
          full_text = multiline_buffer.join("\n")
          execute_input(full_text)
          { stop: false, buffer: [], delimiter: nil }
        else
          multiline_buffer << line
          { stop: false, buffer: multiline_buffer, delimiter: heredoc_delimiter }
        end
      end

      def process_normal_line(line, _multiline_buffer)
        # Only trigger heredoc if line explicitly opens a multiline block (e.g. `<<EOF`, `!plan <<EOF`)
        # NEVER trigger on inline operators like `array << item` or `a << b`
        heredoc_match = line.match(/^\s*(?:[a-zA-Z0-9_!.-]+\s+)?<<[-~]?['"]?([A-Za-z0-9_]+)['"]?\s*$/)
        if heredoc_match && !line.strip.start_with?("#")
          delimiter = heredoc_match[1]
          prefix = line.sub(/<<[-~]?['"]?#{Regexp.escape(delimiter)}['"]?\s*$/, "").strip
          buffer = prefix.empty? ? [] : [prefix]
          { stop: false, buffer: buffer, delimiter: delimiter }
        elsif ["exit", "quit", "!exit", "!quit"].include?(line.strip.downcase)
          stop
          { stop: true, buffer: [], delimiter: nil }
        else
          execute_input(line)
          { stop: false, buffer: [], delimiter: nil }
        end
      end

      def process_multiline_or_line(line)
        execute_input(line)
      end
    end
  end
end
