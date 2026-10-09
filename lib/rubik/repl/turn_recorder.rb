# frozen_string_literal: true

require_relative "../prompt/context_compactor"
require_relative "../coeffects"

module Rubik
  module REPL
    # Plan 61: cross-turn conversational memory policy, included by Shell.
    # Covers sticky route resolution (D-7), per-turn outcome recording for
    # success/failure/cancel (D-2), and the token-budgeted conversation
    # window (D-12). All state lives on Shell; this module only encodes
    # the policy.
    module TurnRecorder
      MAX_CONVERSATION_ENTRIES = Rubik::Prompt::ContextCompactor::DEFAULT_MAX_CONVERSATION_ENTRIES

      # Vakanüvis kök-turn olay adı — harness'in TURN_EVENT sabitiyle eş
      # pinlenir (testler iki taraftan kilitler; isim çelişkisi koşuldan
      # önce patlar).
      TURN_EVENT_TARGET = :turn_finished

      # Plan 61 D-7: sticky routing. Once a conversation has started,
      # free-text turns keep the established provider/model instead of
      # re-running keyword classification every turn (mid-conversation
      # model/style/context-limit churn). `!model` resets the stamp via
      # sync_default_provider; explicit task types (!plan/!goal) never
      # touch it. Disable with `!config set router.sticky false`.
      def resolve_turn_route(text)
        sticky = @config.fetch("router.sticky", true) != false
        return @conversation_route_stamp if sticky && @conversation_route_stamp && !@conversation_history.empty?

        routed = @router.route(task_type: :auto, prompt: text)
        @conversation_route_stamp = routed if routed && routed[:provider]
        routed
      end

      # Plan 61 D-2: every free-text turn — success, failure, cancel —
      # leaves a user/assistant pair in the conversation window so the
      # model keeps the thread and !resume restores it. Failures record a
      # tagged trace plus the attempted-work summary so the next turn knows
      # what was already done.
      def record_turn_outcome!(user_text, assistant_content, tokens: nil, streamed: nil)
        return if user_text.to_s.strip.empty?
        return if assistant_content.nil? || assistant_content.to_s.strip.empty?

        @conversation_history << { role: "user", content: user_text }
        @conversation_history << { role: "assistant", content: assistant_content.to_s }
        trim_conversation_window!
        @recorder&.record_assistant_response(assistant_content.to_s, tokens: tokens, streamed: streamed)
      rescue StandardError => e
        Rubik::Platform.debug_warn("turn outcome recording failed (#{e.class}: #{e.message}); turn lost from conversation memory")
        nil
      end

      def record_failed_turn!(user_text, kind, reason, orchestrator)
        return if @config.fetch("context.log_failed_turns", true) == false

        label = case kind
                when "cancelled" then "[Turn cancelled by user (^C)]"
                when "incomplete" then "[Turn incomplete: #{reason}]"
                else "[Turn failed: #{reason}]"
                end
        summary = if orchestrator.respond_to?(:activity)
                    orchestrator.activity.summary(orchestrator.buffer_manager).to_s.strip
                  else
                    ""
                  end

        # Plan 85 D-3: kronolojik tool listesi (D-2'deki chronological_summary).
        chronicle_enabled = @config.fetch("context.tool_chronicle_in_history", true)
        max_entries = @config.fetch("context.tool_chronicle_max_entries", 15).to_i
        tool_chronicle = if chronicle_enabled &&
                            orchestrator.respond_to?(:activity) &&
                            orchestrator.activity.respond_to?(:chronological_summary)
                           chron = orchestrator.activity.chronological_summary(max_entries: max_entries).strip
                           chron.empty? ? "" : "\nTool calls made:\n#{chron}"
                         else
                           ""
                         end

        parts = []
        parts << label
        parts << "Partial progress before this outcome:\n#{summary}" unless summary.empty?
        parts << tool_chronicle unless tool_chronicle.empty?
        body = "#{parts.first}#{parts[1..].map { |p| "\n#{p}" }.join}"

        # R9: log_failed_turns kapalıysa başarısız turn hiçbir yere
        # kaydedilmez — kronik de dahil (least surprise).
        emit_turn_finished(kind: kind, prompt: user_text, outcome: body, orchestrator: orchestrator)
        record_turn_outcome!(user_text, body)
      rescue StandardError => e
        Rubik::Platform.debug_warn("failed-turn recording crashed (#{e.class}: #{e.message}); failure context lost")
        nil
      end

      # Vakanüvis kök-turn kapısı (root-turn planı 2026-10-04): her REPL
      # turn'ünün sonu deterministik tek satıra indirgenip bus'a düşer.
      # Sessizlik sözleşmesi aynen — :turn_finished WAKE_KINDS dışındadır,
      # tek abone vakanüvis harness'idir; notice yayılmaz. Emisyon asla
      # turn'ü bozmaz: bus yoksa no-op, patlarsa debug_warn.
      def emit_turn_finished(kind:, prompt:, outcome:, orchestrator: nil, tokens: nil)
        return unless @event_bus.respond_to?(:post)

        # Süs bozulursa olay düşmesin: tally degradasyonu kendi rescue'sunda
        # ("") kalır, post için ayrılan dış rescue bozulmuş bus'u yakalar.
        tools = begin
          orchestrator.respond_to?(:activity) ? orchestrator.activity.tool_tally : ""
        rescue StandardError => e
          Rubik::Platform.debug_warn("tool tally failed (#{e.class}: #{e.message}); chronicling without tools")
          ""
        end
        # Loop'ün token sayacı Hash'tir ({input:, output:}) — kronik satırı
        # tek skaler ister; Hash toplamı alınır (Numeric olmayan üye sessizce
        # elenir — üretici asla böyle göndermez, savunma derinliği), diğer
        # şekiller to_i'ye iner. Düzleşme burada (üretici) VE turn_line'da
        # (derinlemesine savunma) yaşar: iki taraf da tek başına dayanıklı.
        tokens_val = tokens.is_a?(Hash) ? tokens.values.filter_map { |v| v.to_i if v.respond_to?(:to_i) }.sum : tokens.to_i
        @event_bus.post(TURN_EVENT_TARGET,
                        { kind: kind.to_s, prompt: prompt.to_s, outcome: outcome.to_s,
                          tools: tools.to_s, tokens: tokens_val }, subsystem: :repl)
      rescue StandardError => e
        Rubik::Platform.debug_warn("turn-finished emission failed (#{e.class}: #{e.message}); turn not chronicled")
        nil
      end

      # Plan 61 D-12: the long-lived REPL memory is trimmed by a token
      # budget (plus an absolute entry cap) so one huge turn cannot evict
      # the whole thread, and eviction order stays oldest-first.
      def trim_conversation_window!
        ceiling = begin
          spec = current_model_spec
          @llm_registry.effective_input_limit_for(spec["provider"], spec["name"])
        rescue StandardError => e
          Rubik::Platform.debug_warn("input ceiling lookup failed (#{e.class}: #{e.message}); using nil budget")
          nil
        end
        @conversation_history = Rubik::Prompt::ContextCompactor.trim_history_to_budget(
          @conversation_history, ceiling: ceiling, max_entries: MAX_CONVERSATION_ENTRIES
        )
      rescue StandardError => e
        Rubik::Log.warn(:repl, "conversation trim failed (#{e.class}: #{e.message}); window may exceed token budget")
        nil
      end

      # Plan 85 D-7 (kök neden): turn sonunda turn içi @history'deki tool ara
      # adımlarını (role: "tool" mesajları) conversation_history'ye kopyalar;
      # hata veya başarı fark etmez. Böylece continue'da model turn sırasındaki
      # tüm bağlamı görür ve "sıfırdan keşfe" başlamaz.
      # loop.rb'ye dokunmaz: caller res[:loop_instance].history üzerinden turn
      # içi @history'yi okur (turn_result zaten loop_instance + history accessor
      # döndürür).
      def merge_turn_tool_history!(turn_history, max_entries: 20)
        return false if turn_history.nil? || turn_history.empty?
        return false unless @config.fetch("context.merge_turn_tool_history", true)

        # Yalnızca tool sonucu taşıyan mesajları filtrele; en SON max_entries
        # adımı al — bir sonraki turn'ün ihtiyacı olan, turn'in güncel arazi
        # durumudur (hangi edit'ler tuttu, son hatalar), turn'in başı değil.
        tool_msgs = turn_history.select do |m|
          role = m[:role] || m["role"]
          role == "tool" || m[:tool_calls] || m["tool_calls"]
        end.last(max_entries)
        return false if tool_msgs.empty?

        @conversation_history.concat(tool_msgs)

        # conversation_history artık tam tool sonuçları taşıdığından trim zorunludur.
        trim_conversation_window!
        true
      rescue StandardError => e
        Rubik::Platform.debug_warn("tool-history merge failed (#{e.class}: #{e.message}); next turn starts without tool context")
        nil
      end

      # Plan 61 D-13: the model spec the CURRENT conversation is bound to
      # (sticky stamp when present), falling back to the default role.
      def current_model_spec
        stamp = @conversation_route_stamp
        return stamp[:spec] if stamp.is_a?(Hash) && stamp[:spec].is_a?(Hash) && stamp[:spec]["provider"]

        @config.model_spec(:default)
      end

      # Pruner apply seam (context-pruner 2026-10-09): turn thread'inde,
      # orchestrator.run pencereyi tohumlamadan HEMEN ÖNCE çağrılır — hem
      # execute_free_text (input_execution.rb) hem !goal (agent_execution.rb
      # ctx.apply_staged_prune_plan! üzerinden). Kopyala-doğrula-takas:
      # take_applicable_plan! yeni dizi döner; herhangi bir ihlalde nil ve
      # pencere olduğu gibi kalır. Replay sırasında atlanır (yeniden
      # oynatılan oturumu budamak kaydı çarpıtır); pruner kapalıysa (coeffect
      # yok) no-op'tur.
      def apply_staged_prune_plan!
        return if @replaying

        harness = Rubik::Coeffects.get(@runtime_manager&.context, Rubik::Coeffects::PRUNER)
        return unless harness

        new_window, receipt = harness.take_applicable_plan!(@conversation_history)
        return unless new_window

        @conversation_history = new_window
        line = "[Pruner] Applied staged plan: dropped #{receipt[:dropped]} unit(s), " \
               "summarized #{receipt[:summarized]} (#{receipt[:skipped_stale]} stale op(s) skipped) — " \
               "window ~#{receipt[:before_tokens]} -> ~#{receipt[:after_tokens]} tokens."
        if @terminal_guard
          @terminal_guard.print_safe_notice(line)
        else
          @output.puts(line)
        end
      rescue StandardError => e
        Rubik::Log.warn(:repl, "staged prune apply failed (#{e.class}: #{e.message}); window untouched")
        nil
      end

      # Session continuity (Plan 34/61): hydrate a recorded session into
      # the live conversation window.
      def resume_session(identifier = :latest)
        root_d = @buffer_manager&.root_dir || Dir.pwd
        home_d = @config&.home_dir || ENV.fetch("HOME", nil)

        target_file = if identifier == :latest || identifier.to_s.downcase == "latest"
                        Rubik::Session::Manager.find_latest_session(root_d, home_d, exclude_file: @recorder&.session_file, config: @config)
                      else
                        Rubik::Session::Manager.find_session(identifier, root_d, home_d, config: @config)
                      end

        return { ok: false, error: "No past session found matching '#{identifier}'" } unless target_file

        res = Rubik::Session::Manager.restore_session(self, target_file)
        @output.puts "[Rubik::Session] Resumed session: #{File.basename(target_file)} (#{res[:turns_hydrated]} dialogue turns hydrated, 0 API tokens used)" if res[:ok]
        res
      end
    end
  end
end
