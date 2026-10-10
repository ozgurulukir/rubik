# frozen_string_literal: true

require_relative "verify_spec"

module Rubik
  module Orchestrator
    module GoalLedger
      # Tri-state FS doğrulaması (goal-ledger planı B). SAF değerlendirme:
      # ledger'ın Monitor'lu SNAPSHOT'ı üzerinde çalışır, tüm FS IO kilit
      # DIŞINDADır; flip kararı Drift/apply_internal_drift!'e aittir.
      #
      # Tri-state sözleşmesi (exhaustive honesty): ok = containment kanıtlı
      # + predicate doğru; failed = containment kanıtlı + predicate yanlış
      # (task → stale, env note → annotate); unknown = KANITLANAMAZ
      # (workspace dışı, EACCES/EPERM, kesilmiş okumada needle yokluğu,
      # malformed spec) — status flip YAPMAZ, yalnızca raporlanır.
      module Verifier
        module_function

        # Adım sınırı girişi (loop.rb execute_steps hook'u): knob FIRST —
        # kapalıysa hiç dokunma. goal_mode? guard'ı çağıran taraftadır.
        def at_step_boundary!(loop_inst)
          ledger = Rubik::Coeffects.get(loop_inst.runtime_manager&.context, Rubik::Coeffects::GOAL_LEDGER)
          return nil unless ledger

          verify!(ledger, trigger: :step, root_dir: loop_inst.buffer_manager&.root_dir || Dir.pwd,
                          config: loop_inst.config)
        end

        # -> nil (knob off / boş) | {rev:, flipped:, unknowns:, note:}
        def verify!(ledger, trigger:, root_dir:, config: nil)
          return nil unless Ledger.verify_enabled?(config)

          snap = ledger.snapshot_doc
          flips, unknowns = evaluate(snap, root_dir)
          return nil if flips.empty? && unknowns.empty?

          outcome = flips.empty? ? nil : ledger.apply_internal_drift!(flips)
          Drift.emit(trigger: trigger, ledger: ledger, flips: flips, unknowns: unknowns, rev: outcome&.dig(:rev))
          { rev: outcome&.dig(:rev), flipped: flips.size, unknowns: unknowns,
            note: flips.empty? ? nil : DriftNote.render(snap: ledger.snapshot_doc) }
        end

        # Kilit dışı: snapshot frozen Hash'lerdir; yalnız disk okunur.
        def evaluate(snap, root_dir)
          flips = []
          unknowns = []
          collect(snap, "tasks", root_dir, flips, unknowns)
          collect(snap, "environment_notes", root_dir, flips, unknowns)
          [flips, unknowns]
        end

        def collect(snap, collection, root_dir, flips, unknowns)
          items = snap[collection]
          return unless items.is_a?(Array)
          return if items.size > VerifySpec::MAX_SPECS_PER_COLLECTION * 4 # flood guardı: caps aşımı incelemeye girmez

          items.each_with_index do |item, idx|
            spec = item.is_a?(Hash) ? item["verify"] : nil
            next if spec.nil?

            verdict, detail = run_spec(spec, root_dir)
            if verdict == :ok
              # ok hiçbir şey yapmaz (sessiz) — stale temizliği yalnızca
              # modelin normal ΔΣ patch'idir; harness asla iyileştirmez.
            elsif verdict == :failed
              flips << entry(collection, idx, item, "failed", detail)
            else
              unknowns << { collection: collection, index: idx, id: item_id(item), reason: detail }
            end
          end
        end

        # -> [:ok|:failed|:unknown, reason]
        def run_spec(raw, root_dir)
          verdict, spec_or_reason = VerifySpec.normalize(raw)
          return [:unknown, spec_or_reason] unless verdict == :ok

          expanded = File.expand_path(spec_or_reason[:path], root_dir)
          return [:unknown, "path escapes the workspace (containment failed closed)"] unless Rubik::Platform.resolved_path_under?(expanded, root_dir)

          if spec_or_reason[:type] == "file_exists"
            File.exist?(expanded) ? [:ok, "file_exists"] : [:failed, "file_exists #{spec_or_reason[:path]}: missing"]
          else
            needle_read(spec_or_reason, expanded)
          end
        rescue Errno::EACCES, Errno::EPERM => e
          [:unknown, "#{e.class.name.delete_prefix('Errno::')}: not readable"]
        rescue StandardError => e
          [:unknown, "#{e.class}: #{e.message}"]
        end

        # Kesilmiş okumada needle yokluğu KANITLANAMAZ → unknown (tri-state
        # dürüstlüğünün kalbi); tam okumada yokluk gerçek yokluktur → failed.
        def needle_read(spec, expanded)
          size = File.size(expanded)
          return [:failed, "file_contains #{spec[:path]}: path is a directory"] if File.directory?(expanded)

          body = File.open(expanded, "rb") { |f| f.read(VerifySpec::READ_CAP_BYTES) }.to_s
          body = Rubik::Platform.safe_utf8(body)
          return [:ok, "file_contains"] if body.include?(spec[:needle])
          return [:unknown, "read truncated at #{VerifySpec::READ_CAP_BYTES} bytes — absence unprovable"] if size > body.bytesize

          [:failed, "file_contains #{spec[:path]}: needle absent"]
        end

        def stale?(item)
          item["status"] == "stale"
        end

        def entry(collection, idx, item, state, reason)
          { collection: collection, index: idx, id: item_id(item), state: state, reason: reason,
            from: item["status"], at: Time.now.utc.iso8601 }
        end

        def item_id(item)
          item.is_a?(Hash) ? item["id"].to_s : ""
        end
      end
    end
  end
end
