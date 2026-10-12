# frozen_string_literal: true

require "stringio"
require_relative "tee_io"

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
              trunc = Rubik::Tools::Truncator.truncate(output_text, max_chars: @config.fetch("tools.max_output_chars", 12_000), strategy: :head_tail)
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

      def execute_free_text(text)
        # Wakeloop fix 2026-10-09: ^C settles the wake debt instead of
        # letting the interrupted turn's own ensure re-arm the cycle. Bound
        # FIRST: every line between here and the rescue clauses can raise
        # (recorder file IO, bus emit), and the ensure reads this local —
        # an unbound read would mask the in-flight exception with a
        # NameError, breaking the "cleanup must never mask" contract.
        interrupted = false
        # Plan 109 staleness rule (see execute_command): a real turn's
        # context already includes the idle-injected notices. The notice
        # turn itself drains first, so this clear is a no-op for it.
        clear_pending_wake_notices! if respond_to?(:clear_pending_wake_notices!)
        @recorder&.record_user_turn(text)
        @event_bus.emit(:prompt_received, prompt: text)

        renderer = md_stream = orchestrator = nil
        routed = resolve_turn_route(text)
        provider = routed[:provider]

        if provider.nil?
          spec_str = routed[:spec].is_a?(Hash) ? "#{routed[:spec]['provider']}/#{routed[:spec]['name']}" : routed[:spec].to_s
          @output.puts "Hata: Model sağlayıcısı başlatılamadı (#{spec_str})."
          record_failed_turn!(text, "failed", "no LLM provider available (#{spec_str})", nil)
          return
        end

        @runtime_manager.provide(:llm_client, provider)

        # Pruner apply seam (context-pruner 2026-10-09): budayıcı bir plan
        # aşamaladıysa pencereyi turn tohumlanmadan ÖNCE takas et (knob
        # kapalıysa no-op; !plan'ın execute_free_text devri ve otonom notice
        # turn'leri buradan geçer).
        apply_staged_prune_plan!

        max_steps = @config.fetch("agent.max_steps", 40).to_i
        warn_ratio = @config.fetch("agent.warn_at_ratio", 0.75).to_f
        theme = self.theme
        renderer = @ui_renderer || Rubik::UI::Renderer.new(config: @config, max_steps: max_steps, output: @output, theme: theme)
        md_enabled = @config.fetch("ui.markdown", "live") != "off"
        md_stream = Rubik::UI::MarkdownStream.new(theme, enabled: md_enabled)

        orchestrator = orchestrator_loop(
          provider: provider,
          model: routed[:model],
          max_steps: max_steps,
          warn_at_ratio: warn_ratio,
          context_limit: routed[:context_limit],
          max_output_tokens: routed[:max_output_tokens],
          on_step: lambda { |step_info|
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
        )
        @active_loop = orchestrator
        res = orchestrator.run(text, conversation_history: @conversation_history)

        while !res[:ok] && res[:error]&.include?("Max steps budget exceeded") && @config.fetch("agent.ask_continue_on_limit", true)
          @output.puts "\n⚠️ [Rubik::Agent] #{res[:error]}"
          ans = ask_yes_no(" [Rubik::Agent] +20 adım ile devam edilsin mi?", default: "n")
          break unless ["y", "yes", "evet"].include?(ans)

          @output.puts " [Rubik::Agent] Adım bütçesi +20 artırılıyor ve görev sürdürülüyor..."
          res = orchestrator.continue_loop(20)

        end

        # Plan 85 D-7 (kök neden): turn içi @history'deki tool ara adımlarını
        # conversation_history'ye kopyala — böylece continue'da model turn sırasındaki
        # bağlamı görür ve "sıfırdan keşfe" başlamaz. res[:loop_instance].history,
        # turn_result'ın döndürdüğü Loop örneğinin @history'sidir.
        merge_turn_tool_history!(
          res[:loop_instance]&.history,
          max_entries: @config.fetch("context.merge_turn_tool_max_entries", 20).to_i
        )

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
      rescue Interrupt
        interrupted = true
        # The user cancelled: queued wake debts settle here. Each queued
        # notice already lives in @conversation_history (idle path injects
        # at route time), so draining loses nothing the model needed.
        clear_pending_wake_notices! if respond_to?(:clear_pending_wake_notices!)
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        # Dedicated event type: restore_session must NOT hydrate this as a
        # dialogue turn (the user_turn recorded at method entry already
        # carries the question; a repl_command-style pair would duplicate it).
        @recorder&.record("cancelled_turn",
                          "question" => text.to_s.strip[0, 80],
                          "reason" => "Interrupted by user (^C)")
        @output.puts "\n⚠️ [Rubik::Agent] Görev kullanıcı tarafından iptal edildi (^C)."
        record_failed_turn!(text, "cancelled", "Interrupted by user (^C)", orchestrator)
      rescue Rubik::LLM::ClientError => e
        # e.message may carry binary bytes (raw HTTP error bodies). Printing
        # or recording those would raise INSIDE this rescue clause, bypassing
        # every sibling handler and surfacing as a bare
        # Encoding::CompatibilityError at the REPL prompt instead of the real
        # LLM error. Sanitize before use.
        message = Rubik::Platform.safe_utf8(e.message)
        @output.puts "[Rubik::LLM Hatası] #{message}"
        record_failed_turn!(text, "failed", message, orchestrator)
      rescue StandardError => e
        message = Rubik::Platform.safe_utf8(e.message)
        @output.puts "[Hata] #{e.class}: #{message}"
        record_failed_turn!(text, "failed", "#{e.class}: #{message}", orchestrator)
      ensure
        @active_loop = nil
        # Flush a half-streamed markdown tail so an interrupt never eats the last
        # line. Cleanup must never mask the in-flight exception (Interrupt, LLM
        # error): each step reports its own failure to stderr instead of raising.
        begin
          md_stream&.finish { |seg| @output.print seg }
        rescue StandardError => e
          warn "[rubik] markdown tail flush failed: #{e.class}: #{e.message}"
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

      # Shared spinner teardown. Cleanup must never mask the in-flight
      # exception (AGENTS.md §5): a spinner whose tick thread died holding
      # the mutex raises ThreadError from synchronize — report it to stderr
      # and continue so the real failure surfaces.
      def kill_spinner!(spinner)
        spinner&.kill
      rescue StandardError => e
        warn "[rubik] spinner cleanup failed: #{e.class}: #{e.message}"
      end

      # Command-dispatch spinner cleanup (both branches).
      def kill_command_spinner!
        kill_spinner!(@ui_renderer&.spinner)
      end
    end
  end
end
