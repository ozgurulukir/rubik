# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Drift işleme (goal-ledger planı B): failed-doğrulamaların iç mutasyona
      # eşlenmesi (flip + last_check annotation), sessiz :ledger_drift
      # emission'u ve reinjection taşıyıcısı DriftNote.
      #
      # Sessizlik sözleşmesi: :ledger_drift WAKE_KINDS DIŞINDADIR —
      # notice/wake üretmez, vakanüvis abone değildir (yalnız kronik
      # bus'da kaybolur); GoalState#notify_finish mold'ü: post fire-and-
      # forget, rescue → Log.warn. Bus yoksa tamamen sessiz atlanır.
      module Drift
        EVENT = :ledger_drift
        MAX_NOTE_ENTRIES = 8
        MAX_NOTE_CHARS = 300

        module_function

        def emit(trigger:, ledger:, flips:, unknowns:, rev:)
          bus = ledger.event_bus
          return unless bus.respond_to?(:post)

          bus.post(EVENT,
                   { trigger: trigger.to_s, rev: rev, flipped: flips.size, unknowns: unknowns.size,
                     entries: flips.map { |f| "#{f[:collection]}[#{f[:index]}] #{f[:id]}: #{f[:reason]}" } },
                   subsystem: :orchestrator, level: :warn)
        rescue StandardError => e
          Rubik::Log.warn(:orchestrator, "ledger drift event post failed: #{e.class}: #{e.message}")
        end
      end

      # Reinjection taşıyıcısı: son doğrulamada FAILED olan (o an stale)
      # girdilerden en yeni MAX_NOTE_ENTRIES tanesi, girdi başına
      # MAX_NOTE_CHARS. Boşsa HİÇ render edilmez (OFF/drift'siz koşu
      # byte-özdeş). Tüm metin xml_escape'ten geçer.
      module DriftNote
        module_function

        def render(snap:)
          entries = []
          Array(snap["tasks"]).each do |task|
            check = task.is_a?(Hash) && task["verify"].is_a?(Hash) ? task["verify"]["last_check"] : nil
            next unless check.is_a?(Hash) && check["state"] == "failed"

            entries << "task #{task['id']} (was #{check['from']}) -> stale: #{check['reason']} at #{check['at']}"
          end
          Array(snap["environment_notes"]).each do |note|
            check = note.is_a?(Hash) && note["verify"].is_a?(Hash) ? note["verify"]["last_check"] : nil
            next unless check.is_a?(Hash) && check["state"] == "failed"

            entries << "environment_note #{note['id']} -> verify failed: #{check['reason']} at #{check['at']}"
          end
          return nil if entries.empty?

          esc = Rubik::Platform.method(:xml_escape)
          body = entries.last(Drift::MAX_NOTE_ENTRIES).map { |line| esc.call(line.to_s.slice(0, Drift::MAX_NOTE_CHARS)) }
          %(<ledger_drift rev="#{snap['rev']}" entries="#{body.size}">\n  #{body.join("\n  ")}\n</ledger_drift>)
        end
      end
    end
  end
end
