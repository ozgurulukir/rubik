# frozen_string_literal: true

require "fileutils"

module Rubik
  module Runtime
    class OverlayStorage
      attr_reader :root_dir, :home_dir

      def initialize(root_dir: Dir.pwd, home_dir: ENV["HOME"])
        @root_dir = File.expand_path(root_dir)
        @home_dir = File.expand_path(home_dir || ENV["HOME"] || ".")
        ensure_directories
      end

      def project_commands_dir
        File.join(@root_dir, ".rubik", "commands")
      end

      def global_commands_dir
        File.join(@home_dir, ".rubik", "commands")
      end

      def ensure_directories
        FileUtils.mkdir_p(project_commands_dir) rescue nil
        FileUtils.mkdir_p(global_commands_dir) rescue nil
      end

      def save_command(name, code, scope: :project, description: "Custom command")
        clean_name = name.to_s.downcase.delete_prefix("!").gsub(/[^a-z0-9_:]/, "_")
        target_dir = (scope.to_sym == :global) ? global_commands_dir : project_commands_dir
        FileUtils.mkdir_p(target_dir)

        file_path = File.join(target_dir, "#{clean_name.gsub(':', '_')}.rb")
        header = <<~RUBY
          # frozen_string_literal: true
          # Rubik Custom Command: !#{clean_name}
          # Scope: #{scope}
          # Description: #{description}

        RUBY

        File.write(file_path, header + code.strip + "\n")
        { ok: true, path: file_path, name: clean_name, scope: scope }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def list_commands
        commands = []

        # Global commands
        Dir.glob(File.join(global_commands_dir, "*.rb")).each do |f|
          name = File.basename(f, ".rb")
          commands << { name: name, scope: :global, path: f }
        end

        # Project commands (can override global)
        Dir.glob(File.join(project_commands_dir, "*.rb")).each do |f|
          name = File.basename(f, ".rb")
          commands << { name: name, scope: :project, path: f }
        end

        commands
      end

      def load_all(shell, manager = nil)
        loaded = []
        list_commands.each do |cmd_meta|
          file_path = cmd_meta[:path]
          cmd_name = cmd_meta[:name]

          begin
            code = File.read(file_path)
            eval_command(shell, cmd_name, code, cmd_meta[:scope])
            loaded << cmd_name
          rescue StandardError => e
            # Log error without stopping startup
          end
        end
        loaded
      end

      def eval_command(shell, cmd_name, code, scope)
        # Allows DSL style:
        # register_command "desc" do |args| ... end
        # or pure ruby handler
        desc_match = code.match(/# Description:\s*(.*)/)
        description = desc_match ? desc_match[1].strip : "Custom #{scope} command"

        proc_handler = if code.include?("->") || code.include?("lambda") || code.include?("proc")
                         eval(code)
                       else
                         eval("->(args, output, shell) {\n#{code}\n}")
                       end

        shell.register_command(cmd_name, description: "#{description} [#{scope}]") do |args|
          out = shell.instance_variable_get(:@output)
          if proc_handler.arity == 1
            proc_handler.call(args)
          elsif proc_handler.arity == 2
            proc_handler.call(args, out)
          else
            proc_handler.call(args, out, shell)
          end
        end
      end
    end
  end
end
