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

      def capture_output(&block)
        StringIO.new.tap { |io| with_output(io, &block) }.string
      end

      # Per-dispatch closed view handed to bang-command handlers (see
      # CommandContext). Cheap by design — holds only the shell reference;
      # the capture-aware IO is read live off the shell, so it reflects
      # with_output's swap at call time.
      def command_context
        Rubik::REPL::CommandContext.new(self)
      end

      def execute_command(parsed)
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
              @ui_renderer&.spinner&.kill
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
        else
          available = @commands.keys.sort.map { |c| "!#{c}" }.join(", ")
          @output.puts "Bilinmeyen komut: !#{parsed.command_name}. Kullanılabilir komutlar: #{available} (!help'e bakın)."
        end
      end

      def execute_free_text(text)
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
        else
          @output.puts "Görev tamamlanamadı: #{res[:error]}"
          record_failed_turn!(text, "incomplete", res[:error], orchestrator)
        end
      rescue Interrupt
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
        begin
          renderer&.spinner&.kill
        rescue StandardError => e
          warn "[rubik] spinner cleanup failed: #{e.class}: #{e.message}"
        end
        flush_subagent_notices! if respond_to?(:flush_subagent_notices!)
      end
    end
  end
end
