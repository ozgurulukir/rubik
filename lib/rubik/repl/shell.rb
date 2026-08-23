# frozen_string_literal: true

require "reline"
require_relative "command_parser"
require_relative "hooks"
require_relative "../runtime"

module Rubik
  module REPL
    class Shell
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager, :snapshot_store, :recorder

      def initialize(config: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil, output: $stdout)
        @config = config || Rubik::Config.new
        @event_bus = event_bus || Rubik::EventBus.new
        @buffer_manager = buffer_manager || Rubik::Buffer::Manager.new
        @snapshot_store = snapshot_store || Rubik::Buffer::SnapshotStore.new
        @ast_graph = Rubik::AST::Graph.new
        effective_root = @buffer_manager&.root_dir || @config&.instance_variable_get(:@root_dir) || Dir.pwd
        effective_home = @config&.instance_variable_get(:@home_dir) || ENV["HOME"]
        @context_index = Rubik::Context::Index.new(root_dir: effective_root)
        @recorder = Rubik::Session::Recorder.new(root_dir: effective_root, home_dir: effective_home)
        @adapter_registry = Rubik::Adapter::Registry.new
        @llm_registry = Rubik::LLM::Registry.new
        @router = Rubik::LLM::Router.new(config: @config, registry: @llm_registry)
        @runtime_manager = Rubik::Runtime::Manager.new
        @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: effective_root, home_dir: effective_home)
        @guard = Rubik::Security::Guard.new
        @output = output
        @hooks = Hooks.new
        @commands = {}
        @running = false

        register_default_commands
        @overlay_storage.load_all(self, @runtime_manager)
      end

      def register_command(name, description:, &handler)
        @commands[name.to_s.downcase] = {
          description: description,
          handler: handler
        }
      end

      def prompt
        project_name = File.basename(Dir.pwd)
        git_branch = detect_git_branch
        branch_part = git_branch ? " [#{git_branch}]" : ""
        "rubik (#{project_name})#{branch_part} > "
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
          @output.puts "Warning: You have unapplied dirty buffer changes!"
        end
        @running = false
      end

      def execute_input(input_text)
        parsed = CommandParser.parse(input_text)
        @recorder.record(parsed.type, input_text) unless @replaying

        case parsed.type
        when :empty
          # noop
        when :command
          execute_command(parsed)
        when :prompt
          execute_free_text(parsed.raw)
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
          @output.puts "[Rubik::Session] Resumed session: #{File.basename(target_file)} (#{res[:replayed_count]} events replayed)"
        end
        res
      end

      def execute_command(parsed)
        cmd_meta = @commands[parsed.command_name]

        if cmd_meta
          @hooks.trigger(:before_command, parsed.command_name, parsed.args)
          cmd_meta[:handler].call(parsed.args)
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
          sandbox_runner: Rubik::Sandbox::Runner.new(root_dir: Dir.pwd),
          shell: self,
          overlay_storage: @overlay_storage,
          runtime_manager: @runtime_manager,
          root_dir: Dir.pwd
        )
      end

      def execute_free_text(text)
        @event_bus.emit(:prompt_received, prompt: text)
        routed = @router.route(task_type: :auto, prompt: text)
        provider = routed[:provider]

        if provider.nil?
          @output.puts "Hata: Model sağlayıcısı başlatılamadı (#{routed[:spec]})."
          return
        end

        tool_reg = build_tool_registry

        orchestrator = Rubik::Orchestrator::Loop.new(
          provider: provider,
          tool_registry: tool_reg,
          model: routed[:model],
          shell: self,
          buffer_manager: @buffer_manager,
          snapshot_store: @snapshot_store,
          context_index: @context_index,
          root_dir: Dir.pwd,
          on_step: lambda { |step_info|
            if step_info[:type] == :tool_call
              @output.puts " [Rubik::Act] Calling #{step_info[:tool]}..."
            end
          }
        )
        res = orchestrator.run(text)
        if res[:ok]
          @output.puts res[:output]
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

        register_command("quit", description: "Exit the REPL shell") { stop }
        register_command("exit", description: "Exit the REPL shell") { stop }

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
          @output.puts "Applied changes to #{applied.size} file(s): #{applied.join(', ')}"
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

        register_command("context", description: "Manage file context index (status|scan|add|drop)") do |args|
          sub = args.first
          case sub
          when "scan"
            @context_index.full_scan
            @output.puts "Context index updated."
          when "add"
            file = args[1]
            @context_index.update_file(file) if file
            @output.puts "Added #{file} to context index."
          else
            summary = @context_index.status_summary
            @output.puts "Indexed files: #{summary[:file_count]}, Languages: #{summary[:languages].join(', ')}"
          end
        end

        register_command("test", description: "Run test suite via active language adapter") do |args|
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
          cmd = args.join(" ")
          @guard.verify_command_safety!(cmd)
          runner = Rubik::Sandbox::Runner.new
          res = runner.run(cmd)
          @output.puts res[:output]
        end

        register_command("plan", description: "Formulate step-by-step plan for a task and ask for confirmation") do |args|
          task = args.join(" ").strip
          if task.empty?
            @output.puts "Kullanım: !plan <görev açıklaması>"
            next
          end

          routed = @router.route(task_type: :plan, prompt: task)
          tool_reg = build_tool_registry
          orchestrator = Rubik::Orchestrator::Loop.new(
            provider: routed[:provider],
            tool_registry: tool_reg,
            model: routed[:model],
            shell: self,
            buffer_manager: @buffer_manager,
            snapshot_store: @snapshot_store,
            context_index: @context_index,
            root_dir: Dir.pwd,
            on_step: ->(info) { @output.puts " [Plan::Step] #{info[:content] || info[:message]}" }
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

          routed = @router.route(task_type: :goal, prompt: goal_text)
          tool_reg = build_tool_registry
          @output.puts "[Rubik::Goal] Starting autonomous goal loop with #{routed[:role]} model (#{routed[:model]})..."
          @output.puts "[Rubik::Goal] Target: #{goal_text}\n"

          orchestrator = Rubik::Orchestrator::Loop.new(
            provider: routed[:provider],
            tool_registry: tool_reg,
            max_steps: 30,
            model: routed[:model],
            shell: self,
            buffer_manager: @buffer_manager,
            snapshot_store: @snapshot_store,
            context_index: @context_index,
            root_dir: Dir.pwd,
            on_step: lambda { |step_info|
              case step_info[:type]
              when :tool_call
                @output.puts " [Rubik::Act] Step #{step_info[:step]}: Calling #{step_info[:tool]} (#{step_info[:args]})"
              when :tool_result
                summary = step_info[:output].to_s.lines.first.to_s.strip
                @output.puts " [Rubik::Verify] -> #{summary[0..100]}"
              when :finish
                @output.puts " [Rubik::Goal] Finished: #{step_info[:message]}"
              end
            }
          )

          res = orchestrator.run(goal_text, goal_mode: true)
          if res[:ok]
            @output.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
            @output.puts res[:output]
            if @buffer_manager.dirty?
              @output.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk."
            end
          else
            @output.puts "\n❌ Goal could not be completed within step limit: #{res[:error]}"
          end
        end

        register_command("model", description: "Switch or view LLM provider/model roles (default, fast, advanced) with auto-persistence") do |args|
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }

          if clean_args.empty?
            mode = @config.fetch("router.mode", "auto")
            def_spec = @config.model_spec(:default)
            fast_spec = @config.model_spec(:fast)
            adv_spec = @config.model_spec(:advanced)
            @output.puts "Model Router Configuration (Mode: #{mode}):"
            @output.puts "  • default  : #{def_spec['provider']}/#{def_spec['name']} (#{def_spec['host'] || 'cloud'})"
            @output.puts "  • fast     : #{fast_spec['provider']}/#{fast_spec['name']} (#{fast_spec['host'] || 'cloud'})"
            @output.puts "  • advanced : #{adv_spec['provider']}/#{adv_spec['name']} (#{adv_spec['host'] || 'cloud'})"
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
          elsif clean_args.first.downcase == "set"
            role = clean_args[1].to_s.downcase
            target = clean_args[2]
            if target.nil? || target.empty?
              @output.puts "Usage: !model set <default|fast|advanced> <provider/name> [--project|--global]"
            else
              prov, mod = target.include?("/") ? target.split("/", 2) : ["ollama", target]
              @config.set_model_spec(role, provider: prov, name: mod, persist: scope)
              @output.puts "Set model role '#{role}' to #{prov}/#{mod} [Saved to #{scope} config]"
            end
          else
            target = clean_args.first
            prov, mod = target.include?("/") ? target.split("/", 2) : ["ollama", target]
            @config.set_model_spec(:default, provider: prov, name: mod, persist: scope)
            @output.puts "Switched default model to #{prov}/#{mod} [Saved to #{scope} config]"
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
            @config.set(key, val, persist: scope)
            @output.puts "Config '#{key}' updated to '#{val}' [Saved to #{scope} config]"
          else
            @output.puts "Usage: !config <get <key> | set <key> <val> [--project|--global] | path>"
          end
        end
      end
    end
  end
end
