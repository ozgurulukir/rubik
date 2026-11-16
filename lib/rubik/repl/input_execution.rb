# frozen_string_literal: true

require "stringio"
require_relative "../log"
require_relative "tee_io"
require_relative "../storage/layout"

module Rubik
  module REPL
    # Öneri 3 (Kademe 2): Shell'den ayrılan girdi yürütme ve çıktı yakalama
    # sorumluluğu. with_output/capture_output I/O geçişini; execute_command
    # bang-komut dispatch'ini (kayıt, truncation, konuşma geçmişi işleme);
    # execute_free_text serbest metin turn'inin tam yaşam döngüsünü kodlar
    # (route → loop kurulum → devam sorusu → araç-geçmişi birleştirme →
    # kayıt → akış/render → hata/iptal temizliği).
    # Durum Shell'de yaşar (@output, @recorder, @conversation_history,
    # @active_loop, ...); bu modül yalnızca yürütme politikasını kodlar.
    module InputExecution
      def with_output(new_io)
        orig = @output
        @output = new_io
        @terminal_guard.output = new_io if @terminal_guard
        yield
      ensure
        @output = orig
        @terminal_guard.output = orig if @terminal_guard
      end

      def capture_output(&)
        StringIO.new.tap { |io| with_output(io, &) }.string
      end

      # Per-dispatch closed view handed to bang-command handlers (see
      # CommandContext). Cheap by design — holds only the shell reference;
      # the capture-aware IO is read live off the shell, so it reflects
      # with_output's swap at call time.
      def command_context
        Rubik::REPL::CommandContext.new(self)
      end

      def execute_command(parsed)
        # Plan 109 staleness rule: this turn's context already includes the
        # idle-injected notices in @conversation_history — a surviving
        # pending wake would turn the next stray Enter into a redundant
        # notice turn.
        clear_pending_wake_notices! if respond_to?(:clear_pending_wake_notices!)
        cmd_name = @plugin_manager ? @plugin_manager.resolve_alias(parsed.command_name) : parsed.command_name.to_s.downcase.delete_prefix("!")
        cmd_meta = @commands[cmd_name]

        if cmd_meta
          @hooks.trigger(:before_command, parsed.command_name, parsed.args)

          # Lifecycle cmds + goal (which self-manages its own history turns)
          untracked_commands = ["quit", "exit", "clear", "reset", "goal"]
          if untracked_commands.include?(parsed.command_name.downcase)
            begin
              cmd_meta[:handler].call(parsed.args, command_context)
            rescue Interrupt
              Rubik::REPL::InterruptHandler.restore_console_after_interrupt
              @output.puts "\n⚠️ [Rubik] Komut kullanıcı tarafından iptal edildi (^C)."
            ensure
              # !goal dahil lifecycle komutları tracked dal ile aynı spinner
              # garantisini taşır (field incident 2026-10-12: !goal'ten kaçan
              # ClientError'da öksüz spinner terminali kilitli gösterdi).
              kill_command_spinner!
            end
          else
            captured = StringIO.new
            cmd_interrupted = false
            with_output(TeeIO.new(@output, captured)) do
              # Built INSIDE the capture swap so ctx.out is the TeeIO — the
              # handler's prints reach the recorder and LLM-history truncation.
              cmd_meta[:handler].call(parsed.args, command_context)
            rescue Interrupt
              cmd_interrupted = true
              Rubik::REPL::InterruptHandler.restore_console_after_interrupt
              @output.puts "\n⚠️ [Rubik] Komut kullanıcı tarafından iptal edildi (^C)."
            ensure
              # A command (!plan/!goal) may leave a live spinner if it died mid-wait.
              kill_command_spinner!
            end
            output_text = captured.string.strip
            if !cmd_interrupted && !output_text.empty?
              clean_raw = Rubik::Security::Redactor.redact(parsed.raw)
              @recorder&.record_repl_command(clean_raw, output_text)
              # Plan 61 D-8: bound what a bang command leaves in LLM memory; the recorder keeps the full text.
              max_chars = Rubik::Storage::Layout.config_get(@config, "tools.max_output_chars", Rubik::Tools::Truncator::DEFAULT_MAX_CHARS)
              # Deliberately context-scoped (issue #349 F8): truncation_strategy is a
              # tool-output contract (the two orchestrator planes); bang-command echo
              # is REPL history capture and stays head_tail, outside the knob's promise.
              trunc = Rubik::Tools::Truncator.truncate(output_text, max_chars: max_chars, strategy: :head_tail)
              @conversation_history << { role: "user", content: clean_raw.delete_prefix("!") } # bangs stay out of LLM history; recorder keeps the literal
              @conversation_history << { role: "assistant", content: trunc[:truncated] ? trunc[:text] : output_text }
              trim_conversation_window!
            end
          end

          @hooks.trigger(:after_command, parsed.command_name, parsed.args)
          reap_dead_kernel_units! if respond_to?(:reap_dead_kernel_units!)
        else
          available = @commands.keys.sort.map { |c| "!#{c}" }.join(", ")
          @output.puts "Bilinmeyen komut: !#{parsed.command_name}. Kullanılabilir komutlar: #{available} (!help'e bakın)."
        end
      end

      # Plan 109 Faz B4: marker prefix makes the system-initiated origin
      # visible in the recorder/session (user decision: honest provenance).
      NOTICE_TURN_MARKER = "[reactive subagent wake-up]"

      # Plan 109 Faz B4: the autonomous notice-evaluation turn. The queued
      # notices ALREADY ride @conversation_history as
      # <subagent_notifications> XML (idle-branch injection); the drained
      # payload only builds a roster so the model can target ids
      # immediately — the prompt never duplicates the XML. Reentrancy is
      # excluded by construction: inside execute_free_text, @active_loop
      # is set before orchestrator.run, so any event arriving mid-turn
      # takes the ACTIVE path (loop inbox), never the idle path — no
      # recursive wake. Wakeloop fix 2026-10-09: the residual idle-path
      # windows (an event landing before @active_loop is set, or in the
      # ensure tail after it is cleared) are closed by @autonomous_turn —
      # route_subagent_notice's idle branch still injects and prints but
      # does not arm the wake while this flag is up, so an autonomous turn
      # can never chain into another one.
      def execute_subagent_notice_turn!
        notices = drain_pending_wake_notices!
        return false if notices.empty?

        roster = notices.map { |n| "#{n[:id]}:#{n[:kind]}" }.uniq.join(", ")
        # Wakeloop fix 2026-10-09: an AUTONOMOUS turn must not spawn another
        # one. Stranded notices this turn leaves behind still reach history
        # (no loss), but they do not re-arm the wake — the prompt comes back
        # and the backlog waits for the user's next Enter.
        begin
          @autonomous_turn = true
          execute_free_text(
            "#{NOTICE_TURN_MARKER} Background subagent activity arrived while the prompt was idle " \
            "(#{roster}). Evaluate the <subagent_notifications> blocks in your conversation history: " \
            "extend the budget of paused-but-promising subagents (manage_subagents action: 'extend_budget'), " \
            "steer with send_message, retrieve finished results (manage_subagents action: 'wait'), " \
            "wrap up or kill stale work, or report outcomes to the user. The user did not type this " \
            "turn — it fired automatically. If nothing needs your attention, finish with a one-line status summary."
          )
        ensure
          @autonomous_turn = false
        end
        true
      end

      # Named phases of the free-text turn (issue #445): execute_free_text is
      # the orchestrator — arming → routing → display/loop assembly → run →
      # settle, with the rescue ladder and ensure teardown delegated to their
      # own helpers below. All helpers run on the Shell (self stays the shell,
      # so @output/@recorder reads are unchanged); every piece of state that
      # was a local of the old monolith (task, renderer, md_stream, theme,
      # md_enabled, orchestrator, interrupted) reaches its consumer explicitly
      # as a parameter — nothing is passed through self or ambient state.
      def execute_free_text(text)
        # Wakeloop fix 2026-10-09: ^C settles the wake debt instead of
        # letting the interrupted turn's own ensure re-arm the cycle. Bound
        # FIRST: every line between here and the rescue clauses can raise
        # (recorder file IO, bus emit), and the ensure reads this local —
        # an unbound read would mask the in-flight exception with a
        # NameError, breaking the "cleanup must never mask" contract.
        interrupted = false
        # Resume bayatlaşması: kullanıcı yeni bir görev yazdıysa duraklatılmış
        # turn teklifi geçersizdir (otonom notice turn'i stash'i ezmez —
        # kullanıcının "devam et"i bir notice turn'ine kurban edilmesin).
        @resumable_turn = nil unless @autonomous_turn
        task = start_free_text_turn!(text)
        renderer = md_stream = orchestrator = nil
        routed = route_free_text!(text)
        return if routed.nil?

        @runtime_manager.provide(:llm_client, routed[:provider])

        # Pruner apply seam (context-pruner 2026-10-09): budayıcı bir plan
        # aşamaladıysa pencereyi turn tohumlanmadan ÖNCE takas et (knob
        # kapalıysa no-op; !plan'ın execute_free_text devri ve otonom notice
        # turn'leri buradan geçer).
        apply_staged_prune_plan!

        max_steps = Rubik::Storage::Layout.config_get(@config, "agent.max_steps", 40).to_i
        warn_ratio = Rubik::Storage::Layout.config_get(@config, "agent.warn_at_ratio", 0.75).to_f
        theme = self.theme
        renderer, md_stream, md_enabled = build_turn_display(theme, max_steps)
        orchestrator = build_turn_orchestrator(routed, max_steps, warn_ratio, renderer, md_stream)

        res = run_free_text_loop(orchestrator, text)
        settle_free_text_result!(text, res, orchestrator: orchestrator, theme: theme, md_enabled: md_enabled)
      rescue Interrupt
        interrupted = true
        handle_interrupted_free_text!(text, task, orchestrator)
      rescue Rubik::LLM::ClientError => e
        handle_llm_client_error!(text, e, orchestrator)
      rescue StandardError => e
        handle_unexpected_error!(text, e, orchestrator)
      ensure
        teardown_free_text_turn!(interrupted, orchestrator, renderer, md_stream)
      end

      # Arming phase: publishes the turn's task-cancellation token (issue #125
      # — the turn owns the subagents it spawns; ^C cancels it and the
      # supervisor stops exactly the owned descendants; detached work and
      # older turns' executions carry different tokens and survive), settles
      # the wake debt and records the turn's entry events. Returns the token
      # for the rescue ladder.
      def start_free_text_turn!(text)
        task = Rubik::Orchestrator::TaskCancellation.new
        @active_task = task
        @runtime_manager&.provide(Rubik::Coeffects::TASK_CANCELLATION, task)
        # Plan 109 staleness rule (see execute_command): a real turn's
        # context already includes the idle-injected notices. The notice
        # turn itself drains first, so this clear is a no-op for it.
        clear_pending_wake_notices! if respond_to?(:clear_pending_wake_notices!)
        @recorder&.record_user_turn(text)
        @event_bus.emit(:prompt_received, prompt: text)
        task
      end

      # Routing phase: resolves the turn route; when no LLM provider is
      # available, reports the failure (message + failed-turn record) and
      # returns nil so the caller aborts the turn — ensure still unwinds.
      def route_free_text!(text)
        routed = resolve_turn_route(text)
        return routed if routed[:provider]

        spec_str = routed[:spec].is_a?(Hash) ? "#{routed[:spec]['provider']}/#{routed[:spec]['name']}" : routed[:spec].to_s
        @output.puts "Hata: Model sağlayıcısı başlatılamadı (#{spec_str})."
        record_failed_turn!(text, "failed", "no LLM provider available (#{spec_str})", nil)
        nil
      end

      # Display phase: builds the step renderer and the live markdown stream.
      # Returns [renderer, md_stream, md_enabled]; md_enabled flows to the
      # batch-render path in settle_free_text_result!.
      def build_turn_display(theme, max_steps)
        renderer = @ui_renderer || Rubik::UI::Renderer.new(config: @config, max_steps: max_steps, output: @output, theme: theme)
        md_enabled = Rubik::Storage::Layout.config_get(@config, "ui.markdown", "live") != "off"
        md_stream = Rubik::UI::MarkdownStream.new(theme, enabled: md_enabled)
        [renderer, md_stream, md_enabled]
      end

      # Loop-assembly phase: builds the orchestrator loop with the turn's
      # step handler wired to the turn's renderer and markdown stream.
      def build_turn_orchestrator(routed, max_steps, warn_ratio, renderer, md_stream)
        orchestrator_loop(
          provider: routed[:provider],
          model: routed[:model],
          max_steps: max_steps,
          warn_at_ratio: warn_ratio,
          context_limit: routed[:context_limit],
          max_output_tokens: routed[:max_output_tokens],
          on_step: turn_step_handler(renderer, md_stream)
        )
      end

      # The per-step streaming policy for free-text turns. The lambda closes
      # over renderer/md_stream (passed explicitly) and the Shell's live
      # @output/@recorder — self at invocation time is still the Shell, the
      # same closure the inline version had.
      def turn_step_handler(renderer, md_stream)
        lambda { |step_info|
          case step_info[:type]&.to_sym
          when :chunk
            renderer.render(step_info) # stops spinner before raw output
            md_stream.push(step_info[:delta]) { |seg| @output.print seg }
            @output.flush if @output.respond_to?(:flush)
          when :chunk_end
            renderer.render(step_info)
            md_stream.finish { |seg| @output.print seg }
            @output.flush if @output.respond_to?(:flush)
          when :tool_call
            @recorder&.record_tool_call(step_info[:tool], step_info[:args], call_id: step_info[:call_id])
            formatted = renderer.render(step_info)
            @output.puts formatted if formatted && !formatted.empty?
            @output.flush if @output.respond_to?(:flush)
          when :tool_result
            @recorder&.record_tool_result(step_info[:tool], step_info[:output], status: step_info[:status] || :ok, call_id: step_info[:call_id])
            formatted = renderer.render(step_info)
            @output.puts formatted if formatted && !formatted.empty?
            @output.flush if @output.respond_to?(:flush)
          else
            formatted = renderer.render(step_info)
            if formatted && !formatted.empty?
              @output.puts formatted
              @output.flush if @output.respond_to?(:flush)
            end
          end
        }
      end

      # Run phase: publishes @active_loop before the loop starts (the
      # reentrancy guard relied on by execute_subagent_notice_turn! and
      # route_subagent_notice's idle branch) and drives the
      # budget-exhausted continue prompt. Returns the final loop result.
      def run_free_text_loop(orchestrator, text)
        @active_loop = orchestrator
        res = orchestrator.run(text, conversation_history: @conversation_history)
        drive_budget_continuations!(orchestrator, res)
      end

      # Resume koşusu: ölü turn'in Loop örneği @active_loop olarak
      # yayınlanır (reentrancy guard, run_free_text_loop ile aynı sözleşme)
      # ve taze display kanalı Loop#resume_turn! devam sözleşmesine
      # geçirilir. Sayaçlar ve @history bilinçli korunur.
      def resume_free_text_loop(orchestrator, renderer, md_stream)
        @active_loop = orchestrator
        res = orchestrator.resume_turn!(reason: RESUME_REASON, on_step: turn_step_handler(renderer, md_stream))
        drive_budget_continuations!(orchestrator, res)
      end

      # Budget-continue döngüsü (run_free_text_loop'tan çıkarıldı): taze
      # turn ile resume koşusu aynı devam-sorusu kalıbını paylaşır.
      def drive_budget_continuations!(orchestrator, res)
        while !res[:ok] && res[:reason] == :budget_exhausted && Rubik::Storage::Layout.config_get(@config, "agent.ask_continue_on_limit", true)
          @output.puts "\n⚠️ [Rubik::Agent] #{res[:error]}"
          ans = ask_yes_no(" [Rubik::Agent] +20 adım ile devam edilsin mi?", default: "n")
          break unless ["y", "yes", "evet"].include?(ans)

          @output.puts " [Rubik::Agent] Adım bütçesi +20 artırılıyor ve görev sürdürülüyor..."
          res = orchestrator.continue_loop(20)

        end
        res
      end

      # Settle phase: merges the turn's tool history, then records and
      # reports the outcome (success render / incomplete report). theme and
      # md_enabled arrive from the display phase for the batch render.
      def settle_free_text_result!(text, res, orchestrator:, theme:, md_enabled:)
        # Plan 85 D-7 (kök neden): turn içi @history'deki tool ara adımlarını
        # conversation_history'ye kopyala — böylece continue'da model turn sırasındaki
        # bağlamı görür ve "sıfırdan keşfe" başlamaz. res[:loop_instance].history,
        # turn_result'ın döndürdüğü Loop örneğinin @history'sidir.
        merge_unseen_turn_tool_history!(res[:loop_instance])

        if res[:ok]
          record_turn_outcome!(text, res[:output].to_s, tokens: res[:tokens], streamed: res[:streamed] == true)

          # Only print the final answer when it was not already streamed
          # live; batch answers get full markdown rendering on capable TTYs.
          # res[:streamed] reflects the FINISHING turn (chunks streamed
          # before a finish tool call count as printed).
          if res[:streamed] != true && !res[:output].to_s.empty?
            rendered = Rubik::UI::MarkdownStream.render_document(res[:output], theme, enabled: md_enabled)
            @output.puts rendered
          end

          @output.puts "\n[Rubik] In-memory buffer updated. Type `!diff` to view, `!apply` to save." if @buffer_manager.dirty?

          # Kök-turn kroniği (root-turn planı 2026-10-04): başarılı turn da
          # vakanüvis'e düşer — subagent'siz geçen oturumlar kroniğe girsin.
          # Bu dalın SON deyimi olmalı: sonrasındaki bir istisna (^C, render
          # hatası) rescue merdivenine düşüp record_failed_turn! ile İKİNCİ
          # bir :turn_finished üretmesin — tek turn, tek kronik satırı.
          emit_turn_finished(kind: "success", prompt: text, outcome: res[:output].to_s,
                             orchestrator: orchestrator, tokens: res[:tokens])
        else
          @output.puts "Görev tamamlanamadı: #{res[:error]}"
          record_failed_turn!(text, "incomplete", res[:error], orchestrator)
        end
      end

      # Turn-exit tool-history merge for non-settle exits (LLM error,
      # unexpected error, ^C). Same policy as settle_free_text_result!'s
      # merge: the loop's in-turn @history carries the tool steps the next
      # turn needs, and merge_turn_tool_history!'s own contract is
      # path-independent ("hata veya başarı fark etmez"). Without this the
      # failure handlers persist only the 15-line chronicle, and "devam et"
      # after a mid-run LLM error makes the model re-discover terrain from
      # a summary instead of the actual last tool results (2026-11-16
      # field report: [41/50] Net::ReadTimeout → re-discovery turn).
      # Ordering contract: call AFTER record_failed_turn! — the outcome
      # text (user + failure pair) must lead the window, otherwise trim's
      # leading-role guard evicts the freshly merged tool messages on a
      # fresh/empty conversation window (first-turn failure).
      def merge_failed_turn_tool_history!(orchestrator)
        return unless orchestrator.respond_to?(:history)

        merge_unseen_turn_tool_history!(orchestrator)
      end

      def merge_unseen_turn_tool_history!(loop_instance)
        return unless loop_instance.respond_to?(:history)

        history = loop_instance.history
        return if history.nil?

        @merged_history_cursors ||= {}.compare_by_identity
        cursor = @merged_history_cursors[loop_instance] || 0
        cursor = 0 if cursor > history.length
        unseen = history[cursor..]
        @merged_history_cursors[loop_instance] = history.length
        return if unseen.nil? || unseen.empty?

        merge_turn_tool_history!(
          unseen,
          max_entries: Rubik::Storage::Layout.config_get(@config, "context.merge_turn_tool_max_entries", 20).to_i
        )
      end

      # ── Hata-sonrası turn resume (2026-11-16) ──────────────────────────
      # LLM hatasıyla ölen serbest-metin turn'i, taze Loop kurulMADAN aynı
      # Loop örneği üzerinden sürdürülebilir: Loop örneği @resumable_turn'te
      # saklanır, kullanıcı resume-niyetinde bir satır yazdığında
      # Loop#resume_turn! devam sözleşmesi (continue_loop/resume! ile aynı
      # execute_steps yolu) işletilir — aynı @history, aynı adım bütçesi
      # (kullanıcının !steps extend'i dahil). Amaç-eşleşmesi BİREBİRDİR:
      # substring eşleşmesi yeni bir görevi yanlışlıkla resume sanabilir.
      RESUME_INTENTS = ["devam et", "devam", "continue", "sürdür"].freeze
      RESUME_PROMPT = "devam et"
      RESUME_REASON = "llm_error_recovery"

      def resumable_turn? = !!@resumable_turn

      # Trailing punctuation allowed after a resume phrase ("devam!…"). Kept as
      # a plain string used with #include? — a /[…]+\z/ regex strip on
      # uncontrolled input is a polynomial-ReDoS hazard (CodeQL rb/polynomial-redos).
      RESUME_TRAILING_PUNCT = ".!?…"

      def resume_intent?(raw)
        return false unless @resumable_turn

        s = raw.to_s.strip.downcase
        idx = s.length - 1
        idx -= 1 while idx >= 0 && RESUME_TRAILING_PUNCT.include?(s[idx])
        # s[0, idx + 1] — NOT s[0..idx]: with idx == -1 a range slice returns
        # the WHOLE string ("!!!"[0..-1] == "!!!"); length-form never does.
        RESUME_INTENTS.include?(s[0, idx + 1])
      end

      # Most-recent-wins: yeni bir turn hatayla ölürse önceki resumable'ın
      # yerine geçer. execute_free_text, otonom notice turn'leri hariç,
      # stash'i temizler (kullanıcı yeni görev seçtiyse resume teklifi
      # bayatlaşır); bir turn başarısız olduktan sonra tekrar dolar.
      def stash_resumable_turn!(orchestrator)
        return false unless orchestrator.respond_to?(:resume_turn!) && orchestrator.respond_to?(:history)

        @resumable_turn = { loop: orchestrator }
        true
      end

      def stash_and_announce_resume!(orchestrator)
        return unless stash_resumable_turn!(orchestrator)

        @output.puts "[Rubik] Turn duraklatıldı (adım #{orchestrator.step_count}/#{orchestrator.max_steps}). " \
                     "'devam et' yazarsan aynı bağlam ve adım bütçesiyle sürer; başka bir şey yazarsan yeni görev olarak koşar."
      end

      # Duraklatılmış turn'in yeniden koşusu: taze turn yaşam döngüsünü
      # (arming → display → settle → rescue merdiveni → ensure teardown)
      # resume sözleşmesiyle birleştirir. Kullanıcının yazdığı satır
      # recorder'a ve konuşma hafızasına "devam et" olarak düşer — dürüst
      # provenance; orijinal görev metni Loop'un kendi @history'sinde
      # yaşamaya devam eder ve modele tekrar gönderilmez.
      def execute_resumed_turn!
        rt = @resumable_turn
        @resumable_turn = nil
        return false unless rt

        interrupted = false
        orchestrator = rt[:loop]
        task = start_free_text_turn!(RESUME_PROMPT)
        renderer = md_stream = nil
        begin
          theme = self.theme
          renderer, md_stream, md_enabled = build_turn_display(theme, orchestrator.max_steps)
          res = resume_free_text_loop(orchestrator, renderer, md_stream)
          settle_free_text_result!(RESUME_PROMPT, res, orchestrator: orchestrator, theme: theme, md_enabled: md_enabled)
        rescue Interrupt
          interrupted = true
          handle_interrupted_free_text!(RESUME_PROMPT, task, orchestrator)
        rescue Rubik::LLM::ClientError => e
          handle_llm_client_error!(RESUME_PROMPT, e, orchestrator)
        rescue StandardError => e
          handle_unexpected_error!(RESUME_PROMPT, e, orchestrator)
        ensure
          teardown_free_text_turn!(interrupted, orchestrator, renderer, md_stream)
        end
        true
      end

      # Interrupt rescue body: the user cancelled — queued wake debts settle
      # here. Each queued notice already lives in @conversation_history (idle
      # path injects at route time), so draining loses nothing the model
      # needed. `interrupted = true` stays in the orchestrator so the ensure
      # reads the flag before this runs.
      def handle_interrupted_free_text!(text, task, orchestrator)
        clear_pending_wake_notices! if respond_to?(:clear_pending_wake_notices!)
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        # Propagate the cancellation to owned work (issue #125) and report the
        # fact: with nothing owned running this reads as an interrupted wait,
        # with owned descendants it reads as a cancelled task tree.
        task_cancellation_lines(cancel_foreground_task!(task)).each { |line| @output.puts line }
        # Dedicated event type: restore_session must NOT hydrate this as a
        # dialogue turn (the user_turn recorded at method entry already
        # carries the question; a repl_command-style pair would duplicate it).
        @recorder&.record("cancelled_turn",
                          "question" => text.to_s.strip[0, 80],
                          "reason" => "Interrupted by user (^C)")
        @output.puts "\n⚠️ [Rubik::Agent] Görev kullanıcı tarafından iptal edildi (^C)."
        record_failed_turn!(text, "cancelled", "Interrupted by user (^C)", orchestrator)
        merge_failed_turn_tool_history!(orchestrator)
      end

      # LLM::ClientError rescue body. e.message may carry binary bytes (raw
      # HTTP error bodies). Printing or recording those would raise INSIDE the
      # rescue clause, bypassing every sibling handler and surfacing as a bare
      # Encoding::CompatibilityError at the REPL prompt instead of the real
      # LLM error. Sanitize before use.
      def handle_llm_client_error!(text, error, orchestrator)
        message = Rubik::Platform.safe_utf8(error.message)
        @output.puts "[Rubik::LLM Hatası] #{message}"
        record_failed_turn!(text, "failed", message, orchestrator)
        merge_failed_turn_tool_history!(orchestrator)
        stash_and_announce_resume!(orchestrator) unless @autonomous_turn
      end

      # StandardError rescue body: same binary-byte sanitization as the LLM
      # error path above.
      def handle_unexpected_error!(text, error, orchestrator)
        message = Rubik::Platform.safe_utf8(error.message)
        @output.puts "[Hata] #{error.class}: #{message}"
        record_failed_turn!(text, "failed", "#{error.class}: #{message}", orchestrator)
        merge_failed_turn_tool_history!(orchestrator)
      end

      # Ensure-phase teardown. Cleanup must never mask the in-flight exception
      # (Interrupt, LLM error): each step reports its own failure to stderr
      # instead of raising. `interrupted` is the orchestrator's local, passed
      # explicitly (Wakeloop fix 2026-10-09: an interrupted turn must not
      # re-arm the wake cycle).
      def teardown_free_text_turn!(interrupted, orchestrator, renderer, md_stream)
        @active_loop = nil
        @active_task = nil
        # Flush a half-streamed markdown tail so an interrupt never eats the last
        # line.
        begin
          md_stream&.finish { |seg| @output.print seg }
        rescue StandardError => e
          Rubik::Log.warn(:repl, "[rubik] markdown tail flush failed: #{e.class}: #{e.message}")
        end
        kill_spinner!(renderer&.spinner)
        flush_subagent_notices! if respond_to?(:flush_subagent_notices!)
        # Session review B3: notices stranded in the ended loop's inbox never
        # reached the model channel and owed no wake — an idle maestro learned
        # about a budget pause only at the next manual prompt (11 min in the
        # reported session). Deliver them into history and arm the wake.
        # Wakeloop fix 2026-10-09: NOT after an interrupt (the user cancelled;
        # the cycle must not resume) and NOT from an autonomous notice turn
        # (a synthetic turn must never spawn another — the prompt comes back).
        if respond_to?(:deliver_stranded_loop_notices!)
          deliver_stranded_loop_notices!(
            orchestrator,
            arm_wake: !interrupted && !@autonomous_turn
          )
        end
        reap_dead_kernel_units! if respond_to?(:reap_dead_kernel_units!)
      end

      # Foreground task cancellation (issue #125): cancel the turn's token and
      # stop its owned descendants within the configured grace period. Returns
      # the supervisor's fact report (nil when no supervisor is wired).
      def cancel_foreground_task!(task)
        supervisor = Rubik::Coeffects.get(@runtime_manager&.context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
        return nil unless task && supervisor.respond_to?(:cancel_owned)

        supervisor.cancel_owned(task, timeout: Rubik::Storage::Layout.config_get(@config, "subagents.cancel_timeout", 2.0))
      rescue StandardError => e
        Rubik::Log.warn(:repl, "[rubik] task cancellation failed: #{e.class}: #{e.message}")
        nil
      end

      # The UI's two truths (issue #125): an interrupt with nothing owned is an
      # interrupted WAIT; one with owned work is a cancelled TASK TREE — and
      # remaining work is named, so an incomplete cleanup is never silent.
      def task_cancellation_lines(outcome)
        return ["⏸️  [Rubik] Bekleme kesildi (^C) — iptal edilecek bağlı alt ajan yok."] unless outcome&.any?

        line = "🛑 [Rubik] Görev ağacı iptal edildi (^C): #{outcome.stopped.size} bağlı alt ajan durduruldu"
        line << ", #{outcome.queued_cancelled.size} kuyruk işi iptal edildi" unless outcome.queued_cancelled.empty?
        if outcome.complete?
          line << "; temizlik tamamlandı."
        else
          remaining = outcome.remaining.map { |r| "#{r[:id]}:#{r[:state]}" }.join(", ")
          line << "; temizlik TAMAMLANMADI — kalan: #{remaining}."
        end
        [line]
      end

      # Shared spinner teardown. Cleanup must never mask the in-flight
      # exception (AGENTS.md §5): a spinner whose tick thread died holding
      # the mutex raises ThreadError from synchronize — report it to stderr
      # and continue so the real failure surfaces.
      def kill_spinner!(spinner)
        spinner&.kill
      rescue StandardError => e
        Rubik::Log.warn(:repl, "[rubik] spinner cleanup failed: #{e.class}: #{e.message}")
      end

      # Command-dispatch spinner cleanup (both branches).
      def kill_command_spinner!
        kill_spinner!(@ui_renderer&.spinner)
      end
    end
  end
end
