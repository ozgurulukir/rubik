# frozen_string_literal: true

require "reline"
require_relative "command_parser"
require_relative "hooks"

module Rubik
  module REPL
    class Shell
      attr_reader :commands, :hooks, :event_bus, :config, :buffer_manager

      def initialize(config: nil, event_bus: nil, buffer_manager: nil, output: $stdout)
        @config = config || Rubik::Config.new
        @event_bus = event_bus || Rubik::EventBus.new
        @buffer_manager = buffer_manager
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
        if @buffer_manager && @buffer_manager.respond_to?(:dirty?) && @buffer_manager.dirty?
          @output.puts "Warning: You have unapplied dirty buffer changes!"
        end
        @running = false
      end

      def execute_input(input_text)
        parsed = CommandParser.parse(input_text)

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

        register_command("quit", description: "Exit the REPL shell") do
          stop
        end

        register_command("exit", description: "Exit the REPL shell") do
          stop
        end

        register_command("status", description: "Show system status") do
          proj = File.basename(Dir.pwd)
          branch = detect_git_branch || "no-git"
          provider = @config.fetch("model.provider", "unknown")
          model = @config.fetch("model.name", "unknown")
          @output.puts "Project: #{proj} (#{branch})"
          @output.puts "Model: #{provider}/#{model}"
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
        @output.puts "Prompt received: #{text}"
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
