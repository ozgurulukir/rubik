# frozen_string_literal: true

require "reline"
require_relative "command_parser"
require_relative "hooks"

module Rubik
  module REPL
    class Shell
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager, :snapshot_store, :recorder

      def initialize(config: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil, output: $stdout)
        @config = config || Rubik::Config.new
        @event_bus = event_bus || Rubik::EventBus.new
        @buffer_manager = buffer_manager || Rubik::Buffer::Manager.new
        @snapshot_store = snapshot_store || Rubik::Buffer::SnapshotStore.new
        @context_index = Rubik::Context::Index.new
        @recorder = Rubik::Session::Recorder.new
        @adapter_registry = Rubik::Adapter::Registry.new
        @llm_registry = Rubik::LLM::Registry.new
        @guard = Rubik::Security::Guard.new
        @output = output
        @hooks = Hooks.new
        @commands = {}
        @running = false

        register_default_commands
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
        @recorder.record(parsed.type, input_text)

        case parsed.type
        when :empty
          # noop
        when :command
          execute_command(parsed)
        when :prompt
          execute_free_text(parsed.raw)
        end
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
              @output.puts "  !#{cmd_name.ljust(12)} - #{meta[:description]}"
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

        register_command("quit", description: "Exit the REPL shell") { stop }
        register_command("exit", description: "Exit the REPL shell") { stop }

        register_command("status", description: "Show system status") do
          proj = File.basename(Dir.pwd)
          branch = detect_git_branch || "no-git"
          provider = @config.fetch("model.provider", "ollama")
          model = @config.fetch("model.name", "llama3")
          @output.puts "Project: #{proj} (#{branch})"
          @output.puts "Model: #{provider}/#{model}"
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

        register_command("model", description: "Switch or view LLM provider/model") do |args|
          if args.empty?
            @output.puts "Active model: #{@config.fetch('model.provider')}/#{@config.fetch('model.name')}"
          else
            target = args.first
            if target.include?("/")
              prov, mod = target.split("/", 2)
              @config.data["model"] ||= {}
              @config.data["model"]["provider"] = prov
              @config.data["model"]["name"] = mod
              @output.puts "Switched model to #{prov}/#{mod}"
            else
              @config.data["model"] ||= {}
              @config.data["model"]["name"] = target
              @output.puts "Switched model name to #{target}"
            end
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

        register_command("config", description: "Get or set runtime config") do |args|
          sub, key, val = args
          if sub == "get"
            @output.puts "#{key} = #{@config.fetch(key)}"
          else
            @output.puts "Config updated."
          end
        end
      end

      def execute_command(parsed)
        cmd_meta = @commands[parsed.command_name]

        if cmd_meta
          @hooks.trigger(:before_command, parsed.command_name, parsed.args)
          cmd_meta[:handler].call(parsed.args)
          @hooks.trigger(:after_command, parsed.command_name, parsed.args)
        else
          @output.puts "Bilinmeyen komut: !#{parsed.command_name}. !help'e bakın."
        end
      end

      def execute_free_text(text)
        @event_bus.emit(:prompt_received, prompt: text)
        prov_name = @config.fetch("model.provider", "ollama")
        model_name = @config.fetch("model.name")

        provider = @llm_registry.get(prov_name)
        if provider.nil?
          @output.puts "Hata: '#{prov_name}' adında bir LLM sağlayıcısı bulunamadı."
          return
        end

        tool_reg = Rubik::Tools::Registry.new
        tool_reg.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
        tool_reg.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
        tool_reg.register(Rubik::Tools::FinishTool.new)

        orchestrator = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: tool_reg, model: model_name)
        res = orchestrator.run(text)
        if res[:ok]
          @output.puts res[:output]
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
    end
  end
end
