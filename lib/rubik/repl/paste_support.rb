# frozen_string_literal: true

module Rubik
  module REPL
    # Multi-line paste desteği (Plan 91): terminaller yapıştırılan bloğu
    # satır-satır ENTER'larla gönderir; Windows konsolunda Reline'in
    # bracketed-paste'i bulunmadığından her satır ayrı bir turn olarak
    # yürütülür. Bu mixin burst algılama (zamanlama + IOGate#in_pasting?)
    # ve explicit `!paste` modunu sağlar. Durum Shell'de yaşar
    # (@config, @reline, @output); burada yalnızca politika kodlanır.
    module PasteSupport
      # Plan 91 — set by the !paste command, consumed once by
      # read_and_process_line to enter explicit paste mode. The named API
      # (not an ivar poke) is what keeps the commands layer out of Shell
      # internals.
      def request_paste!
        @paste_requested = true
      end

      # Bir yapıştırma bloğunun satırlarının "aynı burst" sayılması için
      # iki readline dönüşü arasındaki maksimum süre (ms).
      def paste_join_window_ms
        @config ? @config.fetch("ui.paste_join_window_ms", 120).to_f : 120.0
      end

      # Monotonic saniye sayacı; testler singleton ile ezebilir.
      def paste_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Yapıştırma sürerken giriş tamponunda bekleyen bayt var mı?
      # SADECE gerçek interaktif konsolda güvenilirdir: TTY olmayan
      # ortamlarda (test harness, pipe) Windows/ANSI gate'in in_pasting?
      # yanıltıcı true döndürebildiğinden interactive_input? şarttır.
      def paste_pending?
        return false unless interactive_input?

        gate = @reline.const_defined?(:IOGate) ? @reline::IOGate : nil
        return false unless gate.respond_to?(:in_pasting?)

        gate.in_pasting? == true
      rescue StandardError
        false
      end

      def paste_line_fast?(last_line_at, now)
        return false if last_line_at.nil?

        ((now - last_line_at) * 1000.0) <= paste_join_window_ms
      end

      # Burst collection only makes sense on a real interactive console:
      # with stubbed/piped readline (tests, RUBIK_TEST=1, non-TTY stdin)
      # every stubbed line arrives "instantly", so an ungated collector
      # swallows consecutive scripted lines into one turn. Test harnesses
      # stub this method to exercise the collector deterministically.
      def paste_burst_eligible?
        interactive_input?
      end

      # Explicit paste modu: satırları '.' satırına (veya EOF'a) kadar okur,
      # birleşik metni döndürür. ^C Interrupt olarak yukarı sızar
      # (read_and_process_line'in mevcut rescue'su iptali zaten ele alır).
      def read_paste_block
        @output.puts "[Rubik] Paste modu: metni yapıştırın, bitirmek için tek başına '.' yazın (Ctrl+C iptal)."
        lines = []
        loop do
          line = respond_to?(:safe_readline) ? safe_readline("paste > ", add_history: false) : @reline.readline("paste > ", false)
          break if line.nil? # EOF -> elimizdekiyle bitir
          break if ["\x04", "\x1a"].include?(line)
          break if line.strip == "."

          lines << line
        end
        lines.join("\n")
      end
    end
  end
end
