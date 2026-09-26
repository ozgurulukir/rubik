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
        last_line_at = nil
        print_banner
        Rubik::REPL::InterruptHandler.with_handler do
          while @running
            result = read_and_process_line(multiline_buffer, heredoc_delimiter, last_line_at: last_line_at)
            break if result[:stop]

            multiline_buffer = result[:buffer]
            heredoc_delimiter = result[:delimiter]
            last_line_at = result[:last_line_at]
          end
        end
      ensure
        stop
      end

      # Plan 91 — Explicit paste mode: `!paste` starts a line-collector
      # (PasteSupport#read_paste_block); the joined text is dispatched
      # through the normal prompt path. Executed INSIDE run_interactive
      # (not read_and_process_line) so the paste reader fully replaces
      # readline-based collection while the mode is active.
      def run_paste_mode
        text = read_paste_block
        return { stop: false, buffer: [], delimiter: nil } if text.strip.empty?

        execute_input(text)
        { stop: false, buffer: [], delimiter: nil }
      end

      # Processes one line of interactive input. Returns a hash with:
      #   stop:      true if the REPL should exit
      #   buffer:    updated multiline buffer
      #   delimiter: updated heredoc delimiter (nil if not in heredoc mode)
      #   last_line_at: monotonic timestamp of this accepted line (Plan 91)
      def read_and_process_line(multiline_buffer, heredoc_delimiter, last_line_at: nil)
        # Plan 91 fix: capture-then-reset BEFORE the early return. Resetting
        # only on the fall-through path leaked the flag when paste mode was
        # taken, so every subsequent prompt re-entered run_paste_mode and a
        # test/piped readline returning nil spun the loop forever.
        paste_mode = @paste_requested
        @paste_requested = false
        return run_paste_mode if paste_mode && heredoc_delimiter.nil? && multiline_buffer.empty?

        flush_subagent_notices! if respond_to?(:flush_subagent_notices!)
        @terminal_guard&.flush_notices!
        current_prompt, boxed = prepare_prompt_line(!heredoc_delimiter.nil?)
        line = safe_readline(current_prompt, add_history: false)
        @output.puts box_bottom_border if boxed
        return handle_eof(multiline_buffer, heredoc_delimiter) if line.nil? || line == "\x04" || line == "\x1a"

        # Plan 91 — paste-burst collection: when lines arrive faster than
        # ui.paste_join_window_ms apart (or Reline reports in_pasting?), the
        # pasted lines are buffered and submitted as ONE prompt turn instead
        # of one turn per line. First line still executes immediately if the
        # burst stops; a lone line typed by hand (or Enter pressed in an
        # empty prompt) executes as before.
        #
        # Gated to REAL interactive consoles only: with stubbed/piped readline
        # (tests, RUBIK_TEST=1, non-TTY stdin) every stubbed line arrives
        # "instantly", so an ungated collector would swallow consecutive test
        # lines like "x = a << 1" + "exit" into one turn (seen in test_repl).
        now = paste_clock
        if paste_burst_eligible? && !line.strip.empty? && !heredoc_delimiter &&
           multiline_buffer.empty? &&
           (paste_line_fast?(last_line_at, now) || paste_pending?)
          return collect_paste_burst(line)
        end

        # Push non-empty command to history
        @reline::HISTORY.push(line) if !line.strip.empty? && line != begin
          @reline::HISTORY.to_a.last
        rescue
          nil
        end

        result = if heredoc_delimiter
                   process_heredoc_line(line, multiline_buffer, heredoc_delimiter)
                 else
                   process_normal_line(line, multiline_buffer)
                 end
        result[:last_line_at] = now
        result
      rescue Interrupt
        @output.puts "^C"
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        { stop: false, buffer: [], delimiter: nil }
      rescue StandardError => e
        @output.puts "[REPL Error] #{e.class}: #{e.message}"
        { stop: false, buffer: [], delimiter: nil }
      end

      # Plan 91 — burst collector: keeps reading lines while they arrive
      # within ui.paste_join_window_ms of each other (or Reline reports
      # pending paste input); submits the joined block as a single prompt
      # turn. EOF/Ctrl+D flushes what was collected. Guarded against slow
      # stdin consumers (run_stream-style piping unaffected — this path
      # only runs for interactive readline input).
      def collect_paste_burst(first_line)
        lines = [first_line]
        last_at = paste_clock
        loop do
          line = safe_readline("paste… ", add_history: false)
          now = paste_clock
          break if line.nil? || line == "\x04" || line == "\x1a" # EOF flushes the block

          in_paste = paste_line_fast?(last_at, now) || paste_pending?
          last_at = now
          break unless in_paste # burst ended -> user is typing again; flush

          lines << line
        end
        text = lines.join("\n")
        execute_input(text)
        # Return the final line timestamp so a following paste burst chain
        # (copy #2 right after copy #1) is still detected as fast lines.
        { stop: false, buffer: [], delimiter: nil, last_line_at: last_at }
      end

      def safe_readline(prompt, add_history: false)
        if @terminal_guard
          @terminal_guard.with_reading { @reline.readline(prompt, add_history) }
        else
          @reline.readline(prompt, add_history)
        end
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
