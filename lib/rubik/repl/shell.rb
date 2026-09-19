# frozen_string_literal: true

require "reline"
require "stringio"
require_relative "command_parser"
require_relative "composition"
require_relative "../coeffects"
require_relative "hooks"
require_relative "commands"
require_relative "config_wiring"
require_relative "tee_io"
require_relative "interrupt_handler"
require_relative "confirmations"
require_relative "presentation"
require_relative "turn_recorder"
require_relative "lifecycle"
require_relative "input_loop"
require_relative "input_execution"
require_relative "paste_support"
require_relative "setup_factories"
require_relative "ast_warmup"
require_relative "../runtime"

module Rubik
  module REPL
    class Shell
      include Confirmations
      include Presentation
      include TurnRecorder
      include Lifecycle
      include InputLoop
      include InputExecution
      include PasteSupport
      include SetupFactories
      include AstWarmup

      attr_accessor :output, :conversation_history, :conversation_route_stamp,
                    :active_loop, :agent_caller
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager, :snapshot_store, :recorder,
                  :ast_graph, :context_index, :adapter_registry, :llm_registry, :router, :runtime_manager,
                  :overlay_storage, :lsp_manager, :mcp_manager, :skill_manager, :guard, :sandbox_runner, :cache_store, :indexer_thread,
                  :tool_registry, :input, :reline, :ui_theme, :ui_renderer, :config_cleanups, :task_manager,
                  :subagent_supervisor

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
        # Plan 91 — set by the !paste command, consumed once by
        # read_and_process_line to enter explicit paste mode.
        @paste_requested = false
        @conversation_history = []
        # The in-flight Orchestrator::Loop during a free-text/goal turn, nil at
        # idle. Set for the duration of a turn only (same-thread, synchronous
        # tool execution); the ensure block in execute_free_text/goal clears it.
        # NOT the runtime manager's orchestrator_loop fiber instance — that is
        # a different, rebuilt-on-reprovide object no running turn is using.
        @active_loop = nil

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

      # Öneri 3 (Kademe 4): warm_ast_graph / stop_background_indexer /
      # join_indexer_safely / perform_warm_ast_graph,
      # lib/rubik/repl/ast_warmup.rb mixin'ine taşındı (AST grafiği ısınma ve
      # arka plan indexer yaşam döngüsü).

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
        @subagent_supervisor&.shutdown_all
        @lsp_manager&.stop_all
        @mcp_manager&.stop_all
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

      # Öneri 3 (Kademe 2): with_output / capture_output / execute_command /
      # execute_free_text, lib/rubik/repl/input_execution.rb mixin'ine taşındı
      # (I/O geçişi, bang-komut dispatch'i, serbest metin turn yaşam döngüsü).
      # Öneri 3 (Kademe 3): build_tool_registry / orchestrator_loop /
      # build_orchestrator_loop, lib/rubik/repl/setup_factories.rb mixin'ine
      # taşındı (araç kaydı kurulumu ve orchestrator loop fabrikaları).

      def register_default_commands
        Rubik::REPL::Commands.register_all(self)
      end
    end
  end
end
