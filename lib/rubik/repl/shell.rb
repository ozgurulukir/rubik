# frozen_string_literal: true

require "reline"
require_relative "command_parser"
require_relative "hooks"
require_relative "commands"
require_relative "../runtime"

module Rubik
  module REPL
    class TeeIO
      def initialize(*targets)
        @targets = targets.compact
      end

      def puts(*args)
        @targets.each { |t| t.puts(*args) }
      end

      def print(*args)
        @targets.each { |t| t.print(*args) }
      end

      def printf(*args)
        @targets.each { |t| t.printf(*args) }
      end

      def write(*args)
        @targets.each { |t| t.write(*args) }
      end

      def flush
        @targets.each(&:flush) rescue nil
      end

      def string
        target = @targets.find { |t| t.respond_to?(:string) }
        target&.string || ""
      end

      def reopen(*args)
        @targets.each { |t| t.reopen(*args) if t.respond_to?(:reopen) }
      end
    end

    class Shell
      attr_accessor :output, :conversation_history
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager, :snapshot_store, :recorder,
                  :ast_graph, :context_index, :adapter_registry, :llm_registry, :router,
                  :runtime_manager, :overlay_storage, :lsp_manager, :guard, :sandbox_runner,
                  :cache_store, :indexer_thread

      def initialize(config: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil, output: $stdout, root_dir: nil)
        effective_root = File.expand_path(root_dir || buffer_manager&.root_dir || config&.root_dir || Dir.pwd)
        @config = config || Rubik::Config.new(root_dir: effective_root)
        @event_bus = event_bus || Rubik::EventBus.new

        extra_roots = Array(@config.fetch("workspace.additional_roots", [])).compact
        allow_ext_writes = @config.fetch("workspace.allow_external_writes", false) || false
        auto_index_ext = @config.fetch("workspace.auto_index_additional", true)

        @buffer_manager = buffer_manager || Rubik::Buffer::Manager.new(
          root_dir: effective_root,
          additional_roots: extra_roots,
          allow_external_writes: allow_ext_writes,
          event_bus: @event_bus
        )
        if buffer_manager
          extra_roots.each { |r| @buffer_manager.add_root(r) }
          @buffer_manager.allow_external_writes = allow_ext_writes if @buffer_manager.respond_to?(:allow_external_writes=)
        end

        effective_home = @config&.instance_variable_get(:@home_dir) || ENV["HOME"]
        @snapshot_store = snapshot_store || Rubik::Buffer::SnapshotStore.new(storage_dir: File.join(effective_home, ".rubik", "snapshots", File.basename(effective_root)))
        @cache_store = Rubik::AST::CacheStore.new(root_dir: effective_root, home_dir: effective_home)
        @ast_graph = Rubik::AST::Graph.new
        scanner_roots = auto_index_ext ? extra_roots : []
        @context_index = Rubik::Context::Index.new(root_dir: effective_root, additional_roots: scanner_roots)
        @ast_graph.load_from_cache(@cache_store)
        @recorder = Rubik::Session::Recorder.new(root_dir: effective_root, home_dir: effective_home)
        @adapter_registry = Rubik::Adapter::Registry.new
        @llm_registry = Rubik::LLM::Registry.new(@config)
        @router = Rubik::LLM::Router.new(config: @config, registry: @llm_registry)
        @runtime_manager = Rubik::Runtime::Manager.new
        @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: effective_root, home_dir: effective_home)
        @lsp_manager = Rubik::LSP::Manager.new(config: @config, root_dir: effective_root)
        @guard = Rubik::Security::Guard.new
        @sandbox_runner = Rubik::Sandbox::Runner.new(root_dir: effective_root, config: @config)
        @output = output
        @hooks = Hooks.new
        @commands = {}
        @running = false
        @dirty_turns = 0
        @conversation_history = []

        # Wire core subsystems into Runtime Coeffect Context
        @runtime_manager.provide(:buffer, @buffer_manager)
        @runtime_manager.provide(:snapshot, @snapshot_store)
        @runtime_manager.provide(:lsp, @lsp_manager)
        @runtime_manager.provide(:ast, @ast_graph)
        @runtime_manager.provide(:guard, @guard)
        @runtime_manager.provide(:sandbox, @sandbox_runner)
        @runtime_manager.provide(:adapters, @adapter_registry)
        @runtime_manager.provide(:events, @event_bus)
        @runtime_manager.provide(:config, @config)
        @runtime_manager.provide(:index, @context_index)

        warm_async = @config.fetch("ast.async_warm", ENV["RUBIK_TEST"] != "1")
        warm_ast_graph(async: warm_async)
        register_default_commands
        @overlay_storage.load_all(self, @runtime_manager)
      end

      def sync_context_and_ast(files)
        return unless files && !files.empty?

        root_d = @buffer_manager&.root_dir || Dir.pwd
        files.each do |rel_file|
          @context_index.update_file(rel_file)
          full_path = File.join(root_d, rel_file)
          if File.exist?(full_path)
            @ast_graph.index_file(full_path)
          else
            @ast_graph.remove_file(full_path)
          end
        end
        @ast_graph.save_to_cache(@cache_store) if @cache_store
      end

      def warm_ast_graph(async: true)
        if async
          stop_background_indexer
          @indexer_thread = Thread.new do
            perform_warm_ast_graph
          end
        else
          perform_warm_ast_graph
        end
      end

      def stop_background_indexer
        if @indexer_thread && @indexer_thread.alive?
          @indexer_thread.kill rescue nil
          @indexer_thread.join(0.5) rescue nil
        end
        @indexer_thread = nil
      end

      def perform_warm_ast_graph
        root_d = @buffer_manager&.root_dir || Dir.pwd
        delta = @context_index.incremental_scan
        indexed_files = @ast_graph.file_symbols.keys

        files_to_index = (delta[:added] + delta[:modified]).dup

        @context_index.files.each_key do |rel_file|
          full_path = File.join(root_d, rel_file)
          ext = File.extname(rel_file).downcase
          if Rubik::AST::Extractor.supported_extensions.include?(ext)
            unless indexed_files.include?(full_path) || indexed_files.include?(rel_file)
              files_to_index << rel_file
            end
          end
        end

        files_to_index.uniq.each do |rel_file|
          full_path = File.join(root_d, rel_file)
          ext = File.extname(rel_file).downcase
          if Rubik::AST::Extractor.supported_extensions.include?(ext) && File.exist?(full_path)
            @ast_graph.index_file(full_path)
          end
        end

        delta[:deleted].each do |rel_file|
          full_path = File.join(root_d, rel_file)
          @ast_graph.remove_file(full_path)
        end

        if @cache_store && File.directory?(root_d) && (!files_to_index.empty? || !delta[:deleted].empty?)
          @ast_graph.save_to_cache(@cache_store)
        end
      rescue StandardError
        nil
      end

      def outline_for(file_path)
        full_path = File.expand_path(file_path, @buffer_manager&.root_dir || Dir.pwd)
        if File.exist?(full_path) && !@ast_graph.file_symbols.key?(full_path)
          @ast_graph.index_file(full_path)
        end
        @ast_graph.outline_for(file_path)
      end

      def symbol_definition(symbol_name)
        res = @ast_graph.symbol_definition(symbol_name)
        if res.nil? && @indexer_thread&.alive?
          @indexer_thread.join(0.2) rescue nil
          res = @ast_graph.symbol_definition(symbol_name)
        end
        res
      end

      def search_symbols(query)
        if @ast_graph.symbols.empty? && @indexer_thread&.alive?
          @indexer_thread.join(0.2) rescue nil
        end
        @ast_graph.symbols.values.select do |sym|
          sym.name.downcase.include?(query.downcase)
        end
      end

      def register_command(name, description:, custom: false, &handler)
        key = name.to_s.downcase.delete_prefix("!")
        @commands[key] = {
          description: description,
          handler: handler,
          custom: custom
        }
      end

      def unregister_command(name)
        key = name.to_s.downcase.delete_prefix("!")
        @commands.delete(key)
      end

      def prompt
        project_name = File.basename(Dir.pwd)
        git_branch = detect_git_branch
        branch_part = git_branch ? " [#{git_branch}]" : ""
        show_indicator = @config.fetch("buffer.prompt_indicator", true)
        dirty_count = (@buffer_manager && @buffer_manager.dirty?) ? @buffer_manager.dirty_files.size : 0
        dirty_part = (show_indicator && dirty_count > 0) ? " [DIRTY: #{dirty_count} ✎]" : ""
        "rubik (#{project_name})#{branch_part}#{dirty_part} > "
      end

      def run(input_stream = nil)
        @running = true

        if input_stream
          run_stream(input_stream)
        else
          run_interactive
        end
      end

      def stop
        if @buffer_manager && @buffer_manager.dirty?
          count = @buffer_manager.dirty_files.size
          @output.puts "⚠️ Warning: You have #{count} unapplied dirty buffer change(s)! Run '!apply' to persist or '!diff' to review."
        end
        stop_background_indexer
        @ast_graph.save_to_cache(@cache_store) if @cache_store rescue nil
        @lsp_manager&.stop_all
        @running = false
      end

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
          if interval > 0 && @dirty_turns >= interval
            count = @buffer_manager.dirty_files.size
            @output.puts "💡 [Rubik::Buffer] #{count} unapplied file modification(s) in buffer. Run '!diff' to review or '!apply' to persist to disk."
            @dirty_turns = 0
          end
        else
          @dirty_turns = 0
        end
      end

      def resume_session(identifier = :latest)
        root_d = @buffer_manager&.root_dir || Dir.pwd
        home_d = @config&.instance_variable_get(:@home_dir) || ENV["HOME"]

        target_file = if identifier == :latest || identifier.to_s.downcase == "latest"
                        Rubik::Session::Manager.find_latest_session(root_d, home_d, exclude_file: @recorder&.session_file)
                      else
                        Rubik::Session::Manager.find_session(identifier, root_d, home_d)
                      end

        return { ok: false, error: "No past session found matching '#{identifier}'" } unless target_file

        res = Rubik::Session::Manager.restore_session(self, target_file)
        if res[:ok]
          @output.puts "[Rubik::Session] Resumed session: #{File.basename(target_file)} (#{res[:turns_hydrated]} dialogue turns hydrated, 0 API tokens used)"
        end
        res
      end

      def execute_command(parsed)
        cmd_meta = @commands[parsed.command_name]

        if cmd_meta
          @hooks.trigger(:before_command, parsed.command_name, parsed.args)

          tracked_commands = %w[test lint diff lsp symbols outline refs ast sh apply undo rollback status runtime fibers services workspace roots]
          if tracked_commands.include?(parsed.command_name.downcase)
            captured = StringIO.new
            tee_output = TeeIO.new(@output, captured)
            orig_out = @output
            @output = tee_output
            begin
              cmd_meta[:handler].call(parsed.args)
            ensure
              @output = orig_out
            end
            output_text = captured.string.strip
            unless output_text.empty?
              @recorder&.record_repl_command(parsed.raw, output_text)
              @conversation_history << { role: "user", content: parsed.raw }
              @conversation_history << { role: "assistant", content: output_text }
              @conversation_history = @conversation_history.last(20)
            end
          else
            cmd_meta[:handler].call(parsed.args)
          end

          @hooks.trigger(:after_command, parsed.command_name, parsed.args)
        else
          available = @commands.keys.sort.map { |c| "!#{c}" }.join(", ")
          @output.puts "Bilinmeyen komut: !#{parsed.command_name}. Kullanılabilir komutlar: #{available} (!help'e bakın)."
        end
      end

      def build_tool_registry
        Rubik::Tools::Registry.build_default(
          buffer_manager: @buffer_manager,
          context_index: @context_index,
          ast_graph: @ast_graph,
          adapter_registry: @adapter_registry,
          guard: @guard,
          sandbox_runner: @sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: @config),
          shell: self,
          overlay_storage: @overlay_storage,
          runtime_manager: @runtime_manager,
          lsp_manager: @lsp_manager,
          root_dir: Dir.pwd
        )
      end

      def execute_free_text(text)
        @recorder&.record_user_turn(text)
        @event_bus.emit(:prompt_received, prompt: text)
        routed = @router.route(task_type: :auto, prompt: text)
        provider = routed[:provider]

        if provider.nil?
          @output.puts "Hata: Model sağlayıcısı başlatılamadı (#{routed[:spec]})."
          return
        end

        max_steps = @config.fetch("agent.max_steps", 40).to_i
        warn_ratio = @config.fetch("agent.warn_at_ratio", 0.75).to_f
        tool_reg = build_tool_registry

        formatter = Rubik::REPL::StepFormatter.new(config: @config, max_steps: max_steps)

        orchestrator = Rubik::Orchestrator::Loop.new(
          provider: provider,
          tool_registry: tool_reg,
          max_steps: max_steps,
          warn_at_ratio: warn_ratio,
          model: routed[:model],
          shell: self,
          buffer_manager: @buffer_manager,
          snapshot_store: @snapshot_store,
          context_index: @context_index,
          lsp_manager: @lsp_manager,
          context_limit: routed[:context_limit],
          max_output_tokens: routed[:max_output_tokens],
          config: @config,
          root_dir: Dir.pwd,
          runtime_manager: @runtime_manager,
          on_step: lambda { |step_info|
            formatted = formatter.format(step_info)
            @output.puts formatted if formatted && !formatted.empty?
          }
        )
        res = orchestrator.run(text, conversation_history: @conversation_history)

        while !res[:ok] && res[:error]&.include?("Max steps budget exceeded") && @config.fetch("agent.ask_continue_on_limit", true)
          @output.puts "\n⚠️ [Rubik::Agent] #{res[:error]}"
          @output.print "Adım bütçesine ulaşıldı. +20 adım daha devam edilsin mi? [y/N]: "
          ans = @output.is_a?(StringIO) ? "n" : gets&.strip.to_s.downcase
          if %w[y yes evet].include?(ans)
            @output.puts " [Rubik::Agent] Adım bütçesi +20 artırılıyor ve görev sürdürülüyor..."
            res = orchestrator.continue_loop(20)
          else
            break
          end
        end

        if res[:ok]
          @recorder&.record_assistant_response(res[:output], tokens: res[:tokens])
          @output.puts res[:output]
          @conversation_history << { role: "user", content: text }
          @conversation_history << { role: "assistant", content: res[:output].to_s }
          @conversation_history = @conversation_history.last(20)

          if @buffer_manager.dirty?
            @output.puts "\n[Rubik] In-memory buffer updated. Type `!diff` to view, `!apply` to save."
          end
        else
          @output.puts "Görev tamamlanamadı: #{res[:error]}"
        end
      rescue Rubik::LLM::ClientError => e
        @output.puts "[Rubik::LLM Hatası] #{e.message}"
      rescue StandardError => e
        @output.puts "[Hata] #{e.class}: #{e.message}"
      end

      def run_stream(stream)
        stream.each_line do |line|
          break unless @running

          process_multiline_or_line(line.chomp)
        end
      end

      def run_interactive
        multiline_buffer = []
        heredoc_delimiter = nil

        while @running
          begin
            current_prompt = heredoc_delimiter ? "... > " : prompt
            line = Reline.readline(current_prompt, true)
            break if line.nil?

            if heredoc_delimiter
              if line.strip == heredoc_delimiter
                full_text = multiline_buffer.join("\n")
                execute_input(full_text)
                multiline_buffer.clear
                heredoc_delimiter = nil
              else
                multiline_buffer << line
              end
            elsif line.include?("<<")
              match = line.match(/<<([A-Za-z0-9_]+)/)
              if match
                heredoc_delimiter = match[1]
                multiline_buffer << line
              else
                execute_input(line)
              end
            else
              execute_input(line)
            end
          rescue Interrupt
            @output.puts "^C"
            multiline_buffer.clear
            heredoc_delimiter = nil
            next
          end
        end
      end

      def process_multiline_or_line(line)
        execute_input(line)
      end

      def detect_git_branch
        return nil unless File.directory?(".git")

        head_file = File.join(".git", "HEAD")
        return nil unless File.exist?(head_file)

        content = File.read(head_file).strip
        if content.start_with?("ref: refs/heads/")
          content.sub("ref: refs/heads/", "")
        else
          content[0..6]
        end
      rescue StandardError
        nil
      end

      def register_default_commands
        Rubik::REPL::Commands.register_all(self)
      end
    end
  end
end
