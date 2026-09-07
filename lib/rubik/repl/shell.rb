# frozen_string_literal: true

require "reline"
require "stringio"
require_relative "command_parser"
require_relative "composition"
require_relative "hooks"
require_relative "commands"
require_relative "config_wiring"
require_relative "tee_io"
require_relative "interrupt_handler"
require_relative "confirmations"
require_relative "presentation"
require_relative "turn_recorder"
require_relative "lifecycle"
require_relative "../runtime"

module Rubik
  module REPL
    class Shell
      include Confirmations
      include Presentation
      include TurnRecorder
      include Lifecycle

      attr_accessor :output, :conversation_history, :conversation_route_stamp
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager, :snapshot_store, :recorder,
                  :ast_graph, :context_index, :adapter_registry, :llm_registry, :router, :runtime_manager,
                  :overlay_storage, :lsp_manager, :guard, :sandbox_runner, :cache_store, :indexer_thread,
                  :tool_registry, :input, :reline, :ui_theme, :ui_renderer, :config_cleanups

      # Plan 63 Faz B/C: subsystem construction lives in Composition.build; the
      # shell keeps only phased coordination below (inject → invariant → wire →
      # register → sync → warm-up). initialize stays a ~15-line orchestrator.
      def initialize(config: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil, output: $stdout, input: $stdin, reline: Reline, root_dir: nil,
                     parts: nil)
        parts ||= Composition.build(config: config, root_dir: root_dir, event_bus: event_bus,
                                    buffer_manager: buffer_manager, snapshot_store: snapshot_store)
        inject_parts(parts, injected_buffer: !buffer_manager.nil?)
        @output = output
        @input = input
        @reline = reline
        @hooks = Hooks.new
        @commands = {}
        @running = false
        @dirty_turns = 0
        @conversation_history = []

        wire_runtime_context(parts)
        load_plugins(parts)
        register_runtime_services
        build_and_provide_tool_registry
        sync_ui
        sync_default_llm_route
        warm_up!
      end

      def sync_context_and_ast(files)
        return unless files && !files.empty?

        root_d = @buffer_manager&.root_dir || Dir.pwd
        files.each do |rel_file|
          @context_index.update_file(rel_file)
          full_path = File.join(root_d, rel_file)
          File.exist?(full_path) ? @ast_graph.index_file(full_path) : @ast_graph.remove_file(full_path)
        end
        @ast_graph.save_to_cache(@cache_store) if @cache_store
      end

      def warm_ast_graph(async: true)
        if async
          stop_background_indexer
          @indexer_thread = Thread.new { perform_warm_ast_graph }
        else
          perform_warm_ast_graph
        end
      end

      # Audit 1: teardown/join of the background indexer never crashes shutdown
      # or blocks symbol lookups; detail surfaced via debug_warn.
      def stop_background_indexer
        @indexer_thread.kill if @indexer_thread&.alive?
        join_indexer_safely(0.5)
        @indexer_thread = nil
      rescue StandardError => e
        debug_warn("Background AST indexer teardown failed: #{e.class}: #{e.message}")
        nil
      end

      def join_indexer_safely(timeout)
        @indexer_thread&.join(timeout)
      rescue StandardError => e
        debug_warn("Background AST indexer join failed: #{e.class}: #{e.message}")
        nil
      end

      def perform_warm_ast_graph
        root_d = @buffer_manager&.root_dir || Dir.pwd
        delta = @context_index.incremental_scan
        indexed_files = @ast_graph.file_symbols.keys

        files_to_index = (delta[:added] + delta[:modified]).dup

        @context_index.files.each_key do |rel_file|
          full_path = File.join(root_d, rel_file)
          ext = File.extname(rel_file).downcase
          if Rubik::AST::Extractor.supported_extensions.include?(ext) && !(indexed_files.include?(full_path) || indexed_files.include?(rel_file))
            files_to_index << rel_file
          end
        end

        files_to_index.uniq.each do |rel_file|
          full_path = File.join(root_d, rel_file)
          ext = File.extname(rel_file).downcase
          @ast_graph.index_file(full_path) if Rubik::AST::Extractor.supported_extensions.include?(ext) && File.exist?(full_path)
        end

        delta[:deleted].each do |rel_file|
          full_path = File.join(root_d, rel_file)
          @ast_graph.remove_file(full_path)
        end

        purged = Rubik::Runtime::ASTService.purge_stale_entries!(@ast_graph, @context_index, root_d)

        if @cache_store && File.directory?(root_d) &&
           (!files_to_index.empty? || !delta[:deleted].empty? || purged.positive?)
          @ast_graph.save_to_cache(@cache_store)
        end
      rescue StandardError => e
        @logger&.warn("AST graph warm failed: #{e.message}")
        @event_bus&.emit(:ast_warm_failed, error: e.message)
        nil
      end

      def outline_for(file_path)
        full_path = File.expand_path(file_path, @buffer_manager&.root_dir || Dir.pwd)
        @ast_graph.index_file(full_path) if File.exist?(full_path) && !@ast_graph.file_symbols.key?(full_path)
        @ast_graph.outline_for(file_path)
      end

      def symbol_definition(symbol_name)
        res = @ast_graph.symbol_definition(symbol_name)
        if res.nil? && @indexer_thread&.alive?
          join_indexer_safely(0.2)
          res = @ast_graph.symbol_definition(symbol_name)
        end
        res
      end

      def search_symbols(query)
        join_indexer_safely(0.2) if @ast_graph.symbols.empty? && @indexer_thread&.alive?
        @ast_graph.symbols.values.select { |sym| sym.name.downcase.include?(query.downcase) }
      end

      def register_command(name, description:, custom: false, audience: nil, &handler)
        key = name.to_s.downcase.delete_prefix("!")
        return false if custom && @commands.key?(key) && !@commands[key][:custom]

        resolved = { human: :human, agent: :agent, both: :both }.fetch(audience || (custom ? :both : :human)) do
          raise ArgumentError, "invalid audience: #{audience.inspect}"
        end
        @commands[key] = { description: description, handler: handler, custom: custom, audience: resolved }
        true
      end

      def unregister_command(name)
        @commands.delete(name.to_s.downcase.delete_prefix("!"))
      end

      def run(input_stream = nil)
        @running = true

        if input_stream
          run_stream(input_stream)
        else
          run_interactive
        end
      end

      def running?
        !@running.nil? && @running
      end

      def stop
        if @buffer_manager&.dirty? && (@config.nil? || @config.fetch("buffer.exit_guard", true) != false)
          count = @buffer_manager.dirty_files.size
          @output.puts "⚠️ Warning: You have #{count} unapplied dirty buffer change(s)! Run '!apply' to persist or '!diff' to review."
        end
        @ui_renderer&.spinner&.kill
        stop_background_indexer
        @config_cleanups&.reverse_each(&:call)
        @config_cleanups = []
        @runtime_manager&.dispose!
        @lsp_manager&.stop_all
        Rubik.current_shell = nil if Rubik.current_shell == self
        Rubik.runtime_manager = nil if Rubik.runtime_manager == @runtime_manager
        @running = false
      end
      alias close stop
      alias dispose stop

      # Parses and dispatches a single line of REPL input to the appropriate handler.
      #
      # @param input_text [String] the raw input line from the user
      # @return [void]
      def execute_input(input_text)
        parsed = CommandParser.parse(input_text)
        @recorder.record(parsed.type, input_text) if !@replaying && parsed.type != :empty && parsed.type != :prompt

        case parsed.type
        when :empty
          # noop
        when :command
          execute_command(parsed)
        when :prompt
          execute_free_text(parsed.raw)
        end

        check_dirty_buffer_reminder unless @replaying
      end

      def check_dirty_buffer_reminder
        return unless @buffer_manager

        if @buffer_manager.dirty?
          @dirty_turns += 1
          interval = @config.fetch("buffer.reminder_interval", 3).to_i
          if interval.positive? && @dirty_turns >= interval
            count = @buffer_manager.dirty_files.size
            @output.puts "💡 [Rubik::Buffer] #{count} unapplied file modification(s) in buffer. Run '!diff' to review or '!apply' to persist to disk."
            @dirty_turns = 0
          end
        else
          @dirty_turns = 0
        end
      end

      def allowed_external_dirs
        @buffer_manager&.allowed_external_dirs || []
      end

      def with_output(new_io)
        orig = @output
        @output = new_io
        yield
      ensure
        @output = orig
      end

      def capture_output(&block)
        StringIO.new.tap { |io| with_output(io, &block) }.string
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
              cmd_meta[:handler].call(parsed.args)
            rescue Interrupt
              Rubik::REPL::InterruptHandler.restore_console_after_interrupt
              @output.puts "\n⚠️ [Rubik] Komut kullanıcı tarafından iptal edildi (^C)."
            end
          else
            captured = StringIO.new
            cmd_interrupted = false
            with_output(TeeIO.new(@output, captured)) do
              cmd_meta[:handler].call(parsed.args)
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
              @recorder&.record_repl_command(parsed.raw, output_text)
              # Plan 61 D-8: bound what a bang command leaves in LLM memory; the recorder keeps the full text.
              trunc = Rubik::Tools::Truncator.truncate(output_text, max_chars: @config.fetch("tools.max_output_chars", 12_000), strategy: :head_tail)
              @conversation_history << { role: "user", content: parsed.raw.delete_prefix("!") } # bangs stay out of LLM history; recorder keeps the literal
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

      def build_tool_registry
        Rubik::Tools::Registry.build_default(
          buffer_manager: @buffer_manager, context_index: @context_index, ast_graph: @ast_graph,
          adapter_registry: @adapter_registry, guard: @guard,
          sandbox_runner: @sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: @config),
          shell: self, overlay_storage: @overlay_storage, runtime_manager: @runtime_manager,
          lsp_manager: @lsp_manager, config: @config, root_dir: Dir.pwd
        )
      end

      def orchestrator_loop(opts = {})
        fiber = @runtime_manager&.fibers&.[]("orchestrator_loop")
        return fiber.instance if fiber && fiber.state == :active && fiber.instance && opts.empty?

        build_orchestrator_loop(opts)
      end

      def build_orchestrator_loop(opts = {})
        routed = if opts[:provider]
                   nil
                 else
                   begin
                     @router.route(task_type: opts[:task_type] || :auto, prompt: opts[:prompt])
                   rescue
                     nil
                   end
                 end
        provider = opts[:provider] || routed&.fetch(:provider, nil) || @runtime_manager&.context&.get(:llm_client) || @runtime_manager&.context&.get(:llm)
        return nil unless provider

        merged = opts.merge(
          provider: provider,
          model: opts[:model] || routed&.fetch(:model, nil),
          context_limit: opts[:context_limit] || routed&.fetch(:context_limit, nil),
          max_output_tokens: opts[:max_output_tokens] || routed&.fetch(:max_output_tokens, nil)
        )
        Rubik::Runtime::LoopService.build_loop(@runtime_manager&.context, shell: self, config: merged)
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
        @runtime_manager.provide(:llm, provider)

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
        res = orchestrator.run(text, conversation_history: @conversation_history)

        while !res[:ok] && res[:error]&.include?("Max steps budget exceeded") && @config.fetch("agent.ask_continue_on_limit", true)
          @output.puts "\n⚠️ [Rubik::Agent] #{res[:error]}"
          ans = ask_yes_no(" [Rubik::Agent] +20 adım ile devam edilsin mi?", default: "n")
          break unless ["y", "yes", "evet"].include?(ans)

          @output.puts " [Rubik::Agent] Adım bütçesi +20 artırılıyor ve görev sürdürülüyor..."
          res = orchestrator.continue_loop(20)

        end

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
        @output.puts "[Rubik::LLM Hatası] #{e.message}"
        record_failed_turn!(text, "failed", e.message, orchestrator)
      rescue StandardError => e
        @output.puts "[Hata] #{e.class}: #{e.message}"
        record_failed_turn!(text, "failed", "#{e.class}: #{e.message}", orchestrator)
      ensure
        # Flush a half-streamed markdown tail so an interrupt never eats the last line.
        md_stream&.finish { |seg| @output.print seg }
        renderer&.spinner&.kill
      end

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

      def register_default_commands
        Rubik::REPL::Commands.register_all(self)
      end
    end
  end
end
