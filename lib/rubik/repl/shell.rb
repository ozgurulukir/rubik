# frozen_string_literal: true

require "reline"
require_relative "command_parser"
require_relative "hooks"
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
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager, :snapshot_store, :recorder,
                  :ast_graph, :context_index, :adapter_registry, :llm_registry, :router,
                  :runtime_manager, :overlay_storage, :lsp_manager, :guard, :sandbox_runner,
                  :conversation_history, :cache_store, :indexer_thread

      def initialize(config: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil, output: $stdout, root_dir: nil)
        effective_root = File.expand_path(root_dir || buffer_manager&.root_dir || Dir.pwd)
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

      private

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
        register_command("help", description: "List available commands or show help for a command") do |args|
          if args.empty?
            @output.puts "Available commands:"
            @commands.sort.each do |cmd_name, meta|
              @output.puts "  !#{cmd_name.ljust(14)} - #{meta[:description]}"
            end
          else
            target = args.first.downcase.delete_prefix("!")
            if (meta = @commands[target])
              @output.puts "!#{target}: #{meta[:description]}"
            else
              @output.puts "No help found for !#{target}"
            end
          end
        end

        register_command("commands", description: "List all built-in and synthesized overlay commands") do
          @output.puts "=== Rubik Registered REPL Commands ==="
          @commands.sort.each do |name, meta|
            @output.puts "  !#{name.ljust(16)} : #{meta[:description]}"
          end
        end

        register_command("runtime", description: "Visually display active coeffects, fibers, toolbelt, and accumulator depth") do |args|
          target = args.first&.downcase || "all"
          tool = Rubik::Tools::InspectRuntimeTool.new(@runtime_manager, build_tool_registry, self)
          @output.puts tool.execute(target: target)
        end

        register_command("fibers", description: "Visually display active, pending, and failed fibers with coeffect dependencies") do
          tool = Rubik::Tools::InspectRuntimeTool.new(@runtime_manager, build_tool_registry, self)
          @output.puts tool.execute(target: "fibers")
        end

        register_command("services", description: "Visually display provided runtime coeffects and service registry") do
          tool = Rubik::Tools::InspectRuntimeTool.new(@runtime_manager, build_tool_registry, self)
          @output.puts tool.execute(target: "services")
        end

        register_command("quit", description: "Exit the REPL shell") { stop }
        register_command("exit", description: "Exit the REPL shell") { stop }
        register_command("clear", description: "Clear conversation history / dialogue turns") do
          @conversation_history.clear
          @output.puts "Conversation context cleared. Starting fresh topic."
        end
        register_command("reset", description: "Reset conversation history and in-memory dialogue turns") do
          @conversation_history.clear
          @output.puts "Conversation context reset. Starting fresh topic."
        end

        register_command("status", description: "Show system status") do
          proj = File.basename(Dir.pwd)
          branch = detect_git_branch || "no-git"
          routed = @router.route(task_type: :default)
          @output.puts "Project: #{proj} (#{branch})"
          @output.puts "Default Model: #{routed[:spec]['provider']}/#{routed[:model]}"
          @output.puts "Dirty buffer: #{@buffer_manager.dirty?}"
        end

        register_command("diff", description: "Show unapplied buffer changes") do
          diff_text = @buffer_manager.diff_all
          if diff_text.empty?
            @output.puts "No unapplied buffer changes."
          else
            @output.puts diff_text
          end
        end

        register_command("apply", description: "Apply dirty buffer changes to disk") do
          applied = @buffer_manager.apply!
          sync_context_and_ast(applied)
          @output.puts "Applied changes to #{applied.size} file(s): #{applied.join(', ')}"
        end

        register_command("symbols", description: "Search function, class, struct definitions in AST graph") do |args|
          query = args.join(" ").strip
          if @ast_graph.symbols.empty? && @indexer_thread&.alive?
            @indexer_thread.join(0.2) rescue nil
          end
          if query.empty?
            total = @ast_graph.symbols.size
            @output.puts "AST Symbol Graph (#{total} symbols indexed). Usage: !symbols <name>"
          else
            tool = Rubik::Tools::SearchSymbolsTool.new(@ast_graph)
            @output.puts tool.execute(query: query)
          end
        end

        register_command("outline", description: "Show semantic outline (classes/methods) of a source file") do |args|
          target = args.first
          if target.nil? || target.empty?
            @output.puts "Usage: !outline <file_path>"
          else
            full_path = File.expand_path(target, @buffer_manager&.root_dir || Dir.pwd)
            if File.exist?(full_path) && !@ast_graph.file_symbols.key?(full_path)
              @ast_graph.index_file(full_path)
            end
            tool = Rubik::Tools::GetOutlineTool.new(@ast_graph)
            @output.puts tool.execute(file_path: target)
          end
        end

        register_command("refs", description: "Find call sites and references of a symbol across codebase") do |args|
          sym = args.first
          if @ast_graph.symbols.empty? && @indexer_thread&.alive?
            @indexer_thread.join(0.2) rescue nil
          end
          if sym.nil? || sym.empty?
            @output.puts "Usage: !refs <symbol_name>"
          else
            tool = Rubik::Tools::FindReferencesTool.new(@ast_graph)
            @output.puts tool.execute(symbol_name: sym)
          end
        end

        register_command("ast", description: "Inspect AST outline for a file or definition for a symbol") do |args|
          target = args.first
          if target.nil? || target.empty?
            @output.puts "Usage: !ast <file_path | symbol_name>"
          elsif File.exist?(target)
            full_path = File.expand_path(target, @buffer_manager&.root_dir || Dir.pwd)
            if !@ast_graph.file_symbols.key?(full_path)
              @ast_graph.index_file(full_path)
            end
            tool = Rubik::Tools::GetOutlineTool.new(@ast_graph)
            @output.puts tool.execute(file_path: target)
          else
            if @ast_graph.symbols.empty? && @indexer_thread&.alive?
              @indexer_thread.join(0.2) rescue nil
            end
            tool = Rubik::Tools::GetSymbolTool.new(@ast_graph)
            @output.puts tool.execute(symbol_name: target)
          end
        end

        register_command("undo", description: "Revert the last snapshot") do
          if @snapshot_store.undo(@buffer_manager)
            @output.puts "Undo successful."
          else
            @output.puts "No snapshots to undo."
          end
        end

        register_command("rollback", description: "Rollback to a specific snapshot ID") do |args|
          sid = args.first
          if sid && @snapshot_store.rollback(sid, @buffer_manager)
            @output.puts "Rollback to snapshot #{sid} successful."
          else
            @output.puts "Snapshot #{sid} not found."
          end
        end

        register_command("context", description: "Manage LLM context window & file index (status|compact|scan|add|drop)") do |args|
          sub = args.first
          case sub
          when "scan"
            @context_index.full_scan
            warm_ast_graph(async: false)
            @output.puts "Context index and AST symbol graph updated."
          when "add"
            file = args[1]
            if file
              @context_index.update_file(file)
              full_path = File.join(@buffer_manager.root_dir, file)
              @ast_graph.index_file(full_path) if File.exist?(full_path)
            end
            @output.puts "Added #{file} to context index and AST graph."
          when "drop"
            file = args[1]
            if file
              @context_index.files.delete(file)
              @output.puts "Removed #{file} from context index."
            else
              @output.puts "Usage: !context drop <relative_file_path>"
            end
          when "compact"
            before_tokens = Rubik::Prompt::TokenEstimator.estimate_history(@conversation_history)
            spec = @config.model_spec(:default)
            context_limit = @llm_registry.context_limit_for(spec["provider"], spec["name"])
            max_output = @llm_registry.max_output_tokens_for(spec["provider"], spec["name"])
            context_cfg = @config.fetch("context", {})

            @conversation_history = Rubik::Prompt::ContextCompactor.compact_history(
              @conversation_history,
              context_limit: context_limit,
              max_output_tokens: max_output,
              config: context_cfg,
              force: true
            )
            after_tokens = Rubik::Prompt::TokenEstimator.estimate_history(@conversation_history)
            delta = before_tokens - after_tokens
            @output.puts "Context compaction completed: #{before_tokens} -> #{after_tokens} tokens (reduced #{delta} tokens)."
          else # status or default
            spec = @config.model_spec(:default)
            p_name = spec["provider"]
            m_name = spec["name"]
            context_limit = @llm_registry.context_limit_for(p_name, m_name)
            max_output = @llm_registry.max_output_tokens_for(p_name, m_name)
            ceiling = @llm_registry.effective_input_limit_for(p_name, m_name)
            context_cfg = @config.fetch("context", {})
            strategy = context_cfg["compaction_strategy"] || "hybrid"

            est_tokens = Rubik::Prompt::TokenEstimator.estimate_history(@conversation_history)
            pct = ceiling.positive? ? ((est_tokens.to_f / ceiling) * 100).clamp(0.0, 100.0).round(1) : 0.0
            bar_width = 12
            filled = ((pct / 100.0) * bar_width).round
            empty = bar_width - filled
            bar_str = "[#{"█" * filled}#{"░" * empty}] #{pct}%"

            summary = @context_index.status_summary
            ast_symbols_count = @ast_graph ? @ast_graph.symbols.size : 0

            @output.puts "=== LLM Context Window & In-Memory Status ==="
            @output.puts "Active Model: #{m_name} (#{p_name})"
            @output.puts "Context Window Limit: #{context_limit} tokens"
            @output.puts "Max Output Tokens: #{max_output} tokens"
            @output.puts "Usable Input Ceiling: #{ceiling} tokens"
            @output.puts "Estimated Prompt Tokens: #{est_tokens} / #{ceiling} tokens #{bar_str}"
            @output.puts "Compaction Strategy: #{strategy}"
            @output.puts "Indexed Files: #{summary[:file_count]}, AST Symbols: #{ast_symbols_count}"
            @output.puts "============================================="
          end
        end

        register_command("test", description: "Run test suite via active language adapter") do |args|
          auto_apply_mode = @config.fetch("buffer.auto_apply", "manual").to_s.downcase
          if @buffer_manager&.dirty?
            if %w[on_test always].include?(auto_apply_mode)
              applied = @buffer_manager.apply!
              sync_context_and_ast(applied)
              @output.puts "[Rubik::Buffer] Auto-applied #{applied.size} modified file(s) before test run."
            else
              @output.puts "⚠️ [Rubik::Buffer] Notice: Unapplied buffer changes exist. Tests run against files on disk."
            end
          end
          adapter = @adapter_registry.get("ruby")
          res = adapter.run_tests(Dir.pwd)
          @output.puts res[:output]
        end

        register_command("lint", description: "Run linter/syntax check") do |args|
          target = args.first || "lib/rubik.rb"
          adapter = @adapter_registry.get("ruby")
          res = adapter.check_syntax(target)
          @output.puts res[:output]
        end

        register_command("format", description: "Format target file") do |args|
          target = args.first
          if target
            adapter = @adapter_registry.get("ruby")
            res = adapter.format_code(target)
            @output.puts res[:output]
          end
        end

        register_command("sh", description: "Execute shell command via sandbox runner") do |args|
          auto_apply_mode = @config.fetch("buffer.auto_apply", "manual").to_s.downcase
          if @buffer_manager&.dirty? && %w[on_test always].include?(auto_apply_mode)
            applied = @buffer_manager.apply!
            sync_context_and_ast(applied)
            @output.puts "[Rubik::Buffer] Auto-applied #{applied.size} file(s) before command execution."
          end

          cmd = args.join(" ")
          @guard.verify_command_safety!(cmd)
          runner = Rubik::Sandbox::Runner.new
          res = runner.run(cmd)
          @output.puts res[:output]
        end

        register_command("autoapply", description: "Get or set buffer auto-apply policy (manual|on_test|on_finish|always)") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
          sub = clean_args.first&.downcase

          if sub.nil? || sub == "status"
            cur = @config.fetch("buffer.auto_apply", "manual")
            can_m = @config.fetch("buffer.model_can_apply", true)
            @output.puts "Buffer Auto-Apply Policy:"
            @output.puts "  • Mode             : #{cur} (manual | on_test | on_finish | always)"
            @output.puts "  • Model Can Apply  : #{can_m}"
            @output.puts "  • Prompt Indicator : #{@config.fetch('buffer.prompt_indicator', true)}"
            @output.puts "  • Reminder Interval: #{@config.fetch('buffer.reminder_interval', 3)} turns"
          elsif %w[manual on_test on_finish always].include?(sub)
            @config.set("buffer.auto_apply", sub, persist: scope)
            @output.puts "Buffer auto-apply policy set to '#{sub}' [Saved to #{scope} config]"
          else
            @output.puts "Usage: !autoapply <manual | on_test | on_finish | always | status> [--project|--global]"
          end
        end

        register_command("plan", description: "Formulate step-by-step plan for a task and ask for confirmation") do |args|
          task = args.join(" ").strip
          if task.empty?
            @output.puts "Kullanım: !plan <görev açıklaması>"
            next
          end

          plan_steps = @config.fetch("agent.plan_max_steps", 15).to_i
          routed = @router.route(task_type: :plan, prompt: task)
          tool_reg = build_tool_registry
          formatter = Rubik::REPL::StepFormatter.new(config: @config, max_steps: plan_steps)
          orchestrator = Rubik::Orchestrator::Loop.new(
            provider: routed[:provider],
            tool_registry: tool_reg,
            max_steps: plan_steps,
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

          @output.puts "[Rubik::Plan] Generating plan using #{routed[:role]} model (#{routed[:model]})..."
          res = orchestrator.run(task, plan_only: true)

          if res[:ok]
            @output.puts "\n=== Proposed Plan ==="
            @output.puts res[:output]
            @output.puts "=====================\n"
            @output.print "Bu plan uygulansın mı? [y/N]: "
            ans = @output.is_a?(StringIO) ? "y" : gets&.strip.to_s.downcase
            if %w[y yes evet].include?(ans)
              @output.puts "[Rubik::Act] Executing approved plan..."
              execute_free_text("Execute the following approved plan step by step:\n#{res[:output]}")
            else
              @output.puts "[Rubik] Plan iptal edildi."
            end
          else
            @output.puts "Plan üretilemedi: #{res[:error]}"
          end
        end

        register_command("goal", description: "Run long-running autonomous goal loop until all tests pass") do |args|
          goal_text = args.join(" ").strip
          if goal_text.empty?
            @output.puts "Kullanım: !goal <hedef açıklaması>"
            next
          end

          @recorder&.record_user_turn("!goal #{goal_text}")
          goal_steps = @config.fetch("agent.goal_max_steps", 80).to_i
          warn_ratio = @config.fetch("agent.warn_at_ratio", 0.75).to_f
          routed = @router.route(task_type: :goal, prompt: goal_text)
          tool_reg = build_tool_registry
          @output.puts "[Rubik::Goal] Starting autonomous goal loop (Budget: #{goal_steps} steps) with #{routed[:role]} model (#{routed[:model]})..."
          @output.puts "[Rubik::Goal] Target: #{goal_text}\n"

          formatter = Rubik::REPL::StepFormatter.new(config: @config, max_steps: goal_steps)
          orchestrator = Rubik::Orchestrator::Loop.new(
            provider: routed[:provider],
            tool_registry: tool_reg,
            max_steps: goal_steps,
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

          res = orchestrator.run(goal_text, goal_mode: true, conversation_history: @conversation_history)
          if res[:ok]
            @recorder&.record_assistant_response(res[:output])
            @output.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
            @output.puts res[:output]
            @conversation_history << { role: "user", content: "!goal #{goal_text}" }
            @conversation_history << { role: "assistant", content: res[:output].to_s }
            @conversation_history = @conversation_history.last(20)

            if @buffer_manager.dirty?
              @output.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk."
            end
          else
            @output.puts "\n❌ Goal could not be completed within step limit: #{res[:error]}"
          end
        end

        register_command("steps", description: "Manage or view agentic step budget (max_steps, goal_max_steps, plan_max_steps)") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }

          if clean_args.empty? || clean_args.first.downcase == "status"
            cur_max = @config.fetch("agent.max_steps", 40)
            goal_max = @config.fetch("agent.goal_max_steps", 80)
            plan_max = @config.fetch("agent.plan_max_steps", 15)
            warn_r = @config.fetch("agent.warn_at_ratio", 0.75)
            ask_c = @config.fetch("agent.ask_continue_on_limit", true)

            @output.puts "=== Agentic Step Budget Configuration ==="
            @output.puts "  • Default Task Max Steps : #{cur_max}"
            @output.puts "  • Goal Mode Max Steps    : #{goal_max}"
            @output.puts "  • Plan Mode Max Steps    : #{plan_max}"
            @output.puts "  • Warning Threshold      : #{(warn_r.to_f * 100).to_i}% (#{(cur_max.to_i * warn_r.to_f).ceil}. adım)"
            @output.puts "  • Ask Continue on Limit  : #{ask_c}"
          elsif clean_args.first.downcase == "goal"
            num = clean_args[1].to_i
            if num <= 0
              @output.puts "Usage: !steps goal <number> [--project|--global]"
            else
              @config.set("agent.goal_max_steps", num, persist: scope)
              @output.puts "Goal mode max steps set to #{num} [Saved to #{scope} config]"
            end
          elsif clean_args.first.downcase == "plan"
            num = clean_args[1].to_i
            if num <= 0
              @output.puts "Usage: !steps plan <number> [--project|--global]"
            else
              @config.set("agent.plan_max_steps", num, persist: scope)
              @output.puts "Plan mode max steps set to #{num} [Saved to #{scope} config]"
            end
          elsif clean_args.first.to_i > 0
            num = clean_args.first.to_i
            @config.set("agent.max_steps", num, persist: scope)
            @output.puts "Agent default max steps set to #{num} [Saved to #{scope} config]"
          else
            @output.puts "Usage: !steps [<number> | goal <number> | plan <number> | status] [--project|--global]"
          end
        end

        register_command("verbosity", description: "Get or set UI verbosity level (quiet|normal|verbose|debug)") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }

          if clean_args.empty? || clean_args.first.downcase == "status"
            cur_level = @config.verbosity_level
            cur_name = case cur_level
                       when Rubik::REPL::StepFormatter::LEVEL_QUIET then "quiet"
                       when Rubik::REPL::StepFormatter::LEVEL_NORMAL then "normal"
                       when Rubik::REPL::StepFormatter::LEVEL_VERBOSE then "verbose"
                       when Rubik::REPL::StepFormatter::LEVEL_DEBUG then "debug"
                       else "normal"
                       end
            @output.puts "Active verbosity: #{cur_name} (level #{cur_level})"
            @output.puts "Levels:"
            @output.puts "  0 - quiet   (Minimal output, final answer only)"
            @output.puts "  1 - normal  (Clean step & tool progress, default)"
            @output.puts "  2 - verbose (Detailed args, result previews, token estimates)"
            @output.puts "  3 - debug   (Full raw I/O, latencies, diagnostics)"
          else
            raw_val = clean_args.first.downcase
            level = Rubik::REPL::StepFormatter.normalize_level(raw_val)
            level_name = case level
                         when Rubik::REPL::StepFormatter::LEVEL_QUIET then "quiet"
                         when Rubik::REPL::StepFormatter::LEVEL_NORMAL then "normal"
                         when Rubik::REPL::StepFormatter::LEVEL_VERBOSE then "verbose"
                         when Rubik::REPL::StepFormatter::LEVEL_DEBUG then "debug"
                         else "normal"
                         end
            @config.set("ui.verbosity", level_name, persist: scope)
            @output.puts "Verbosity set to #{level_name} (level #{level}) [Saved to #{scope} config]"
          end
        end

        register_command("verbose", description: "Toggle verbose mode on/off") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
          sub = clean_args.first&.downcase

          if sub == "on" || sub == "true" || sub == "1"
            @config.set("ui.verbosity", "verbose", persist: scope)
            @output.puts "Verbose mode enabled (level 2) [Saved to #{scope} config]"
          elsif sub == "off" || sub == "false" || sub == "0"
            @config.set("ui.verbosity", "normal", persist: scope)
            @output.puts "Verbose mode disabled (normal, level 1) [Saved to #{scope} config]"
          else
            cur = @config.verbosity_level
            new_level = (cur == Rubik::REPL::StepFormatter::LEVEL_VERBOSE) ? "normal" : "verbose"
            num = (new_level == "verbose") ? 2 : 1
            @config.set("ui.verbosity", new_level, persist: scope)
            @output.puts "Verbose mode toggled to #{new_level} (level #{num}) [Saved to #{scope} config]"
          end
        end

        register_command("provider", description: "Manage LLM providers and models: list | add <name> [type] <url> [--key=...] [--model=...] | add-model <provider> <model> [--context=LIMIT] | remove-model <provider> <model> | set <provider> <field> <val> | remove <provider>") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
          sub = clean_args.first&.downcase || "list"

          case sub
          when "list", "ls", "status"
            cat = @llm_registry.catalog
            @output.puts "=== Configured LLM Providers & Models ==="
            cat.each do |p_name, info|
              @output.puts "\n• Provider: #{p_name.upcase} (#{info[:type]})"
              @output.puts "  Endpoint: #{info[:endpoint]}"
              if info[:models].empty?
                @output.puts "  Models  : (Default / dynamically requested via model name)"
              else
                @output.puts "  Models  :"
                info[:models].each do |m|
                  @output.puts "    - #{m[:name].ljust(35)} [Context: #{m[:context_limit]} tokens]"
                end
              end
            end
          when "add"
            p_name = clean_args[1]&.downcase
            arg2 = clean_args[2]
            arg3 = clean_args[3]

            p_type = "openai_compatible"
            p_endpoint = nil

            if arg2 && (arg2.start_with?("http://") || arg2.start_with?("https://"))
              p_endpoint = arg2
            elsif arg2 && arg3 && (arg3.start_with?("http://") || arg3.start_with?("https://"))
              p_type = arg2.downcase
              p_endpoint = arg3
            elsif arg2 && arg3
              p_type = arg2.downcase
              p_endpoint = arg3
            end

            if p_name.nil? || p_name.empty? || p_endpoint.nil? || p_endpoint.empty?
              @output.puts "Usage: !provider add <name> [type] <endpoint_url> [--key=API_KEY | --key-env=ENV_VAR] [--model=NAME] [--context=LIMIT] [--project|--global]"
            elsif !p_endpoint.start_with?("http://") && !p_endpoint.start_with?("https://")
              @output.puts "Error: Endpoint must be a valid HTTP/HTTPS URL (starting with http:// or https://). Received: '#{p_endpoint}'\nUsage: !provider add <name> [type] <endpoint_url> [--key=API_KEY | --key-env=ENV_VAR] [--model=NAME] [--context=LIMIT] [--project|--global]"
            else
              key_arg = clean_args.find { |a| a.start_with?("--key=") || a.start_with?("--api-key=") }
              key_env_arg = clean_args.find { |a| a.start_with?("--key-env=") }
              model_arg = clean_args.find { |a| a.start_with?("--model=") }
              context_arg = clean_args.find { |a| a.start_with?("--context=") }

              api_key = key_arg ? key_arg.split("=", 2).last : nil
              key_env = key_env_arg ? key_env_arg.split("=", 2).last : nil
              m_name = model_arg ? model_arg.split("=", 2).last : "default"
              c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768

              p_spec = {
                "type" => p_type,
                "endpoint" => p_endpoint,
                "api_key" => api_key,
                "api_key_env" => key_env,
                "models" => [
                  { "name" => m_name, "context_limit" => c_limit }
                ]
              }.compact

              @config.set("providers.#{p_name}", p_spec, persist: scope)
              @llm_registry.load_from_config(@config)
              @output.puts "Successfully added provider '#{p_name}' (#{p_type} -> #{p_endpoint}) with model '#{m_name}' [Saved to #{scope} config]."
            end
          when "add-model", "model-add"
            p_name = clean_args[1]&.downcase
            m_name = clean_args[2]
            if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
              @output.puts "Usage: !provider add-model <provider_name> <model_name> [--context=LIMIT] [--project|--global]"
            else
              p_spec = @config.fetch("providers.#{p_name}", {})
              if p_spec.empty?
                @output.puts "Provider '#{p_name}' not found. Add it first via !provider add."
              else
                context_arg = clean_args.find { |a| a.start_with?("--context=") }
                c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768

                models = Array(p_spec["models"]).dup
                models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                models << { "name" => m_name, "context_limit" => c_limit }
                p_spec["models"] = models

                @config.set("providers.#{p_name}", p_spec, persist: scope)
                @llm_registry.load_from_config(@config)
                @output.puts "Added model '#{m_name}' (#{c_limit} tokens) to provider '#{p_name}' [Saved to #{scope} config]."
              end
            end
          when "remove-model", "model-remove", "model-rm"
            p_name = clean_args[1]&.downcase
            m_name = clean_args[2]
            if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
              @output.puts "Usage: !provider remove-model <provider_name> <model_name> [--project|--global]"
            else
              p_spec = @config.fetch("providers.#{p_name}", {})
              if p_spec.empty?
                @output.puts "Provider '#{p_name}' not found."
              else
                models = Array(p_spec["models"]).dup
                models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                p_spec["models"] = models

                @config.set("providers.#{p_name}", p_spec, persist: scope)
                @llm_registry.load_from_config(@config)
                @output.puts "Removed model '#{m_name}' from provider '#{p_name}' [Saved to #{scope} config]."
              end
            end
          when "set"
            p_name = clean_args[1]&.downcase
            field = clean_args[2]&.downcase
            val = clean_args[3]
            if p_name.nil? || p_name.empty? || field.nil? || val.nil?
              @output.puts "Usage: !provider set <name> <endpoint|key|key-env|type> <value> [--project|--global]"
            else
              p_spec = @config.fetch("providers.#{p_name}", {})
              if p_spec.empty?
                @output.puts "Provider '#{p_name}' not found."
              else
                case field
                when "key", "api_key"
                  p_spec["api_key"] = val
                when "key-env", "key_env", "api_key_env"
                  p_spec["api_key_env"] = val
                when "endpoint", "url", "host"
                  if !val.start_with?("http://") && !val.start_with?("https://")
                    @output.puts "Error: Endpoint must be a valid HTTP/HTTPS URL (starting with http:// or https://). Received: '#{val}'"
                    next
                  end
                  p_spec["endpoint"] = val
                when "type"
                  p_spec["type"] = val
                else
                  p_spec[field] = val
                end

                @config.set("providers.#{p_name}", p_spec, persist: scope)
                @llm_registry.load_from_config(@config)
                @output.puts "Updated provider '#{p_name}' field '#{field}' to '#{val}' [Saved to #{scope} config]."
              end
            end
          when "remove", "rm", "delete"
            p_name = clean_args[1]&.downcase
            if p_name.nil? || p_name.empty?
              @output.puts "Usage: !provider remove <name> [--project|--global]"
            else
              @config.data["providers"]&.delete(p_name)
              @config.save!(scope)
              @llm_registry.load_from_config(@config)
              @output.puts "Removed provider '#{p_name}' [Saved to #{scope} config]."
            end
          else
            @output.puts "Usage: !provider <list | add <name> <type> <endpoint> | add-model <provider> <model> | remove-model <provider> <model> | set <provider> <field> <val> | remove <name>> [--project|--global]"
          end
        end

        register_command("providers", description: "List all configured LLM providers, endpoints, and models") do |args|
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
          cat = @llm_registry.catalog
          @output.puts "=== Configured LLM Providers & Models ==="
          cat.each do |p_name, info|
            @output.puts "\n• Provider: #{p_name.upcase} (#{info[:type]})"
            @output.puts "  Endpoint: #{info[:endpoint]}"
            if info[:models].empty?
              @output.puts "  Models  : (Default / dynamically requested via model name)"
            else
              @output.puts "  Models  :"
              info[:models].each do |m|
                @output.puts "    - #{m[:name].ljust(35)} [Context: #{m[:context_limit]} tokens]"
              end
            end
          end
        end

        register_command("lsp", description: "Manage Language Server Protocol (LSP) integration (status|on|off|diag|start <lang>|stop <lang>)") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
          sub = clean_args.first&.downcase || "status"

          case sub
          when "status"
            summary = @lsp_manager.status_summary
            @output.puts "=== LSP Integration Status ==="
            @output.puts "  • Enabled          : #{summary[:enabled]}"
            @output.puts "  • Auto Diagnostics : #{summary[:auto_diagnostics]}"
            @output.puts "\nConfigured Language Servers:"
            summary[:servers].each do |lang, info|
              status_mark = info[:running] ? "🟢 RUNNING" : (info[:available] ? "⚪ AVAILABLE" : "🔴 NOT FOUND")
              diags_str = info[:running] ? " (#{info[:diagnostics_count]} diagnostics)" : ""
              @output.puts "  • #{lang.ljust(8)} : #{info[:server_cmd].ljust(16)} -> #{status_mark}#{diags_str}"
            end
          when "on", "enable"
            @config.set("lsp.enabled", true, persist: scope)
            @output.puts "LSP integration enabled [Saved to #{scope} config]."
          when "off", "disable"
            @config.set("lsp.enabled", false, persist: scope)
            @lsp_manager.stop_all
            @output.puts "LSP integration disabled and running servers stopped [Saved to #{scope} config]."
          when "diag", "diagnostics"
            target_file = clean_args[1]
            if target_file
              diags = @lsp_manager.diagnostics_for(target_file)
              if diags.empty?
                @output.puts "No LSP diagnostics or errors for '#{target_file}'."
              else
                @output.puts "=== LSP Diagnostics for #{target_file} (#{diags.size} issue(s)) ==="
                diags.each do |d|
                  sev = d["severity"] == 1 ? "ERROR" : "WARN"
                  line = (d.dig("range", "start", "line") || 0) + 1
                  @output.puts "  • [#{sev}] Line #{line}: #{d['message']}"
                end
              end
            else
              all = @lsp_manager.all_diagnostics
              if all.empty? || all.values.flatten.empty?
                @output.puts "No active LSP diagnostics across workspace."
              else
                all.each do |fpath, diags|
                  next if diags.empty?

                  @output.puts "\nFile: #{fpath} (#{diags.size} issue(s)):"
                  diags.each do |d|
                    sev = d["severity"] == 1 ? "ERROR" : "WARN"
                    line = (d.dig("range", "start", "line") || 0) + 1
                    @output.puts "  • [#{sev}] Line #{line}: #{d['message']}"
                  end
                end
              end
            end
          when "start"
            lang = clean_args[1]
            if lang.nil? || lang.empty?
              @output.puts "Usage: !lsp start <go|rust|zig|c|python|ruby>"
            else
              res = @lsp_manager.start_client(lang)
              @output.puts res[:ok] ? res[:message] : "Error: #{res[:error]}"
            end
          when "stop"
            lang = clean_args[1]
            if lang.nil? || lang.empty?
              @lsp_manager.stop_all
              @output.puts "Stopped all active LSP servers."
            else
              res = @lsp_manager.stop_client(lang)
              @output.puts res[:ok] ? res[:message] : "Error: #{res[:error]}"
            end
          else
            @output.puts "Usage: !lsp <status | on | off | diag [file] | start <lang> | stop [lang]> [--project|--global]"
          end
        end

        register_command("model", description: "Switch or view LLM provider/model roles (default, fast, advanced) with auto-persistence") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }

          if clean_args.empty? || clean_args.first.downcase == "list"
            mode = @config.fetch("router.mode", "auto")
            def_spec = @config.model_spec(:default)
            fast_spec = @config.model_spec(:fast)
            adv_spec = @config.model_spec(:advanced)

            def_limit = @llm_registry.context_limit_for(def_spec["provider"], def_spec["name"])
            fast_limit = @llm_registry.context_limit_for(fast_spec["provider"], fast_spec["name"])
            adv_limit = @llm_registry.context_limit_for(adv_spec["provider"], adv_spec["name"])

            @output.puts "Model Router Configuration (Mode: #{mode}):"
            @output.puts "  • default  : #{def_spec['provider']}/#{def_spec['name']} [Context: #{def_limit} tokens] (#{def_spec['host'] || 'cloud'})"
            @output.puts "  • fast     : #{fast_spec['provider']}/#{fast_spec['name']} [Context: #{fast_limit} tokens] (#{fast_spec['host'] || 'cloud'})"
            @output.puts "  • advanced : #{adv_spec['provider']}/#{adv_spec['name']} [Context: #{adv_limit} tokens] (#{adv_spec['host'] || 'cloud'})"
            @output.puts "Global Config  : #{@config.global_config_path}"
            @output.puts "Project Config : #{@config.project_config_path}"
          elsif clean_args.first.downcase == "route"
            mode = clean_args[1].to_s.downcase
            if %w[auto manual].include?(mode)
              @config.set("router.mode", mode, persist: scope)
              @output.puts "Router mode set to #{mode} [Saved to #{scope} config]"
            else
              @output.puts "Usage: !model route <auto|manual>"
            end
          elsif clean_args.first.downcase == "add"
            p_name = clean_args[1]&.downcase
            m_name = clean_args[2]
            if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
              @output.puts "Usage: !model add <provider_name> <model_name> [--context=LIMIT] [--project|--global]"
            else
              p_spec = @config.fetch("providers.#{p_name}", {})
              if p_spec.empty?
                @output.puts "Provider '#{p_name}' not found. Add provider first via !provider add."
              else
                context_arg = clean_args.find { |a| a.start_with?("--context=") }
                c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768
                models = Array(p_spec["models"]).dup
                models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                models << { "name" => m_name, "context_limit" => c_limit }
                p_spec["models"] = models

                @config.set("providers.#{p_name}", p_spec, persist: scope)
                @llm_registry.load_from_config(@config)
                @output.puts "Added model '#{m_name}' (#{c_limit} tokens) to provider '#{p_name}' [Saved to #{scope} config]."
              end
            end
          elsif clean_args.first.downcase == "set"
            role = clean_args[1].to_s.downcase
            target = clean_args[2]
            if target.nil? || target.empty?
              @output.puts "Usage: !model set <default|fast|advanced> <provider/name> [--project|--global]"
            else
              prov, mod = target.include?("/") ? target.split("/", 2) : ["ollama", target]
              @config.set_model_spec(role, provider: prov, name: mod, persist: scope)
              limit = @llm_registry.context_limit_for(prov, mod)
              @output.puts "Set model role '#{role}' to #{prov}/#{mod} [Context: #{limit} tokens] [Saved to #{scope} config]"
            end
          else
            target = clean_args.first
            prov, mod = target.include?("/") ? target.split("/", 2) : ["ollama", target]
            @config.set_model_spec(:default, provider: prov, name: mod, persist: scope)
            limit = @llm_registry.context_limit_for(prov, mod)
            @output.puts "Switched default model to #{prov}/#{mod} [Context: #{limit} tokens] [Saved to #{scope} config]"
          end
        end

        register_command("history", description: "List recent session history") do |args|
          limit = (args.first || 20).to_i
          hist = @recorder.read_history(limit)
          hist.each_with_index do |item, idx|
            @output.puts " #{idx + 1}: #{item['payload']}"
          end
        end

        register_command("replay", description: "Replay session file") do |args|
          path = args.first
          replayer = Rubik::Session::Replayer.new(self)
          if replayer.replay_file(path)
            @output.puts "Replay completed."
          else
            @output.puts "Session file not found: #{path}"
          end
        end

        register_command("session", description: "Manage recorded sessions (list|resume [id]|info)") do |args|
          sub = args.first&.downcase || "list"
          root_d = @buffer_manager&.root_dir || Dir.pwd
          home_d = @config&.instance_variable_get(:@home_dir) || ENV["HOME"]

          case sub
          when "list"
            sessions = Rubik::Session::Manager.list_sessions(root_d, home_d)
            if sessions.empty?
              @output.puts "No recorded sessions found for this workspace."
            else
              @output.puts "=== Recorded Sessions (#{sessions.size}) ==="
              sessions.each_with_index do |s, idx|
                mark = (s[:path] == @recorder.session_file) ? " [CURRENT]" : ""
                @output.puts "  #{idx + 1}. #{s[:id]} (#{s[:scope]}) - #{s[:event_count]} events - Last: \"#{s[:last_prompt]}\"#{mark}"
              end
            end
          when "resume", "continue", "load"
            target_id = args[1] || :latest
            res = resume_session(target_id)
            @output.puts "Resume failed: #{res[:error]}" unless res[:ok]
          when "info"
            @output.puts "Active Session File: #{@recorder.session_file}"
            @output.puts "Total Events in Session: #{@recorder.events.size}"
          else
            @output.puts "Usage: !session <list | resume [id] | info>"
          end
        end

        register_command("config", description: "Get, set, or view runtime configuration paths") do |args|
          sub = args.first
          if sub == "get"
            key = args[1]
            @output.puts "#{key} = #{@config.fetch(key)}"
          elsif sub == "path" || sub == "paths"
            @output.puts "Global Config  : #{@config.global_config_path} (exists: #{File.exist?(@config.global_config_path)})"
            @output.puts "Project Config : #{@config.project_config_path} (exists: #{File.exist?(@config.project_config_path)})"
          elsif sub == "set"
            key = args[1]
            val = args[2]
            scope = args.include?("--project") || args.include?("-p") ? :project : :global
            typed_val = @config.set(key, val, persist: scope)
            if key == "workspace.additional_roots" && typed_val.is_a?(Array)
              typed_val.each { |r| @buffer_manager.add_root(r) }
              if @config.fetch("workspace.auto_index_additional", true)
                @context_index.additional_roots = @buffer_manager.additional_roots
                @context_index.full_scan
                warm_ast_graph(async: false)
              end
            elsif key == "workspace.allow_external_writes"
              @buffer_manager.allow_external_writes = typed_val
            end
            @output.puts "Config '#{key}' updated to '#{val}' [Saved to #{scope} config]"
          else
            @output.puts "Usage: !config <get <key> | set <key> <val> [--project|--global] | path>"
          end
        end

        workspace_handler = lambda do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          is_rw = args.include?("--rw") || args.include?("-w")
          clean_args = args.reject { |a| %w[--project -p --global -g --rw -w].include?(a) }
          sub = clean_args.first&.downcase || "list"

          effective_root = @buffer_manager&.root_dir || Dir.pwd

          case sub
          when "list", "status"
            extra = @buffer_manager&.additional_roots || []
            rw_set = @buffer_manager&.rw_roots || Set.new
            glob_rw = @buffer_manager&.allow_external_writes || false
            auto_idx = @config.fetch("workspace.auto_index_additional", true)

            @output.puts "=== Configured Workspace Roots ==="
            @output.puts "  • [PRIMARY] #{effective_root} (Read-Write)"
            if extra.empty?
              @output.puts "  (No additional workspace roots configured)"
            else
              extra.each_with_index do |r, idx|
                mode_str = (glob_rw || rw_set.include?(r)) ? "Read-Write" : "Read-Only"
                @output.puts "  • [EXTRA #{idx + 1}] #{r} (#{mode_str})"
              end
            end
            @output.puts "External Writes Allowed Globally : #{glob_rw}"
            @output.puts "Auto-Index Additional Roots      : #{auto_idx}"
          when "add"
            target_path = clean_args[1]
            if target_path.nil? || target_path.empty?
              @output.puts "Usage: !workspace add <path> [--rw] [--project|--global]"
            else
              begin
                @guard.verify_root_safety!(target_path)
              rescue Rubik::Security::BlockedWriteError => e
                @output.puts "Security Error: #{e.message}"
                next
              end

              expanded = @buffer_manager.add_root(target_path, rw: is_rw)

              # Sync context index
              if @config.fetch("workspace.auto_index_additional", true)
                @context_index.additional_roots = @buffer_manager.additional_roots
                @context_index.full_scan
                warm_ast_graph(async: false)
              end

              # Persist to config
              current_roots = Array(@config.fetch("workspace.additional_roots", [])).dup
              current_roots << target_path unless current_roots.include?(target_path)
              @config.set("workspace.additional_roots", current_roots, persist: scope)

              mode_str = is_rw ? "Read-Write" : "Read-Only"
              @output.puts "[Rubik::Workspace] Added additional root: #{expanded} (Mode: #{mode_str}) [Saved to #{scope} config]"
            end
          when "remove", "rm", "delete"
            target_path = clean_args[1]
            if target_path.nil? || target_path.empty?
              @output.puts "Usage: !workspace remove <path> [--project|--global]"
            else
              expanded = @buffer_manager.remove_root(target_path)

              # Sync context index
              if @config.fetch("workspace.auto_index_additional", true)
                @context_index.additional_roots = @buffer_manager.additional_roots
                @context_index.full_scan
                warm_ast_graph(async: false)
              end

              # Persist to config
              current_roots = Array(@config.fetch("workspace.additional_roots", [])).dup
              current_roots.reject! { |r| File.expand_path(r, effective_root) == expanded || r == target_path }
              @config.set("workspace.additional_roots", current_roots, persist: scope)

              @output.puts "[Rubik::Workspace] Removed additional root: #{expanded} [Saved to #{scope} config]"
            end
          else
            @output.puts "Usage: !workspace <list | add <path> [--rw] | remove <path>> [--project|--global]"
          end
        end

        register_command("workspace", description: "Manage multiple workspace roots (list|add <path> [--rw]|remove <path>)", &workspace_handler)
        register_command("roots", description: "Alias for !workspace", &workspace_handler)
      end
    end
  end
end
