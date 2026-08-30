# frozen_string_literal: true

require "fileutils"
require "json"

module Rubik
  module Runtime
    class OverlayStorage
      attr_reader :root_dir, :home_dir

      def initialize(root_dir: Dir.pwd, home_dir: ENV.fetch("HOME", nil))
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

      def project_tools_dir
        File.join(@root_dir, ".rubik", "tools")
      end

      def global_tools_dir
        File.join(@home_dir, ".rubik", "tools")
      end

      def ensure_directories
        [project_commands_dir, global_commands_dir, project_tools_dir, global_tools_dir].each do |dir|
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          warn "[WARN] Failed to create overlay directory #{dir}: #{e.message}" if ENV["RUBIK_DEBUG"]
        end
      end

      def save_command(name, code, scope: :project, description: "Custom command")
        clean_name = name.to_s.downcase.delete_prefix("!").gsub(/[^a-z0-9_:]/, "_")
        target_dir = scope.to_sym == :global ? global_commands_dir : project_commands_dir
        FileUtils.mkdir_p(target_dir)

        file_path = File.join(target_dir, "#{clean_name.gsub(':', '_')}.rb")
        header = <<~RUBY
          # frozen_string_literal: true
          # Rubik Custom Command: !#{clean_name}
          # Scope: #{scope}
          # Description: #{description}

        RUBY

        File.write(file_path, "#{header}#{code.strip}\n")
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

      def load_all(shell, _manager = nil)
        loaded = []
        list_commands.each do |cmd_meta|
          file_path = cmd_meta[:path]
          cmd_name = cmd_meta[:name]

          begin
            code = File.read(file_path)
            eval_command(shell, cmd_name, code, cmd_meta[:scope])
            loaded << cmd_name
          rescue StandardError
            # Log error without stopping startup
          end
        end
        loaded
      end

      def eval_command(shell, cmd_name, code, scope)
        desc_match = code.match(/# Description:\s*(.*)/)
        description = desc_match ? desc_match[1].strip : "Custom #{scope} command"

        # Interpolasyon sonrasi degerlendirilen kodun gorunumu:
        #   ->(args, output, shell) {
        #   <kullanici kodu>
        #   }
        proc_handler = if code.include?("->") || code.include?("lambda") || code.include?("proc")
                         eval(code) # rubocop:disable Security/Eval -- overlay özelliginin çekirdegi; kaynak sentez-sandbox dogrulamasindan geçer
                       else
                         eval("->(args, output, shell) {\n#{code}\n}", binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- ayni gerekçe; görünüm yorumu üstte
                       end

        shell.register_command(cmd_name, description: "#{description} [#{scope}]", custom: true) do |args|
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

      def save_tool(name, code, scope: :project, description: "Custom native tool", params_schema: nil, risk: :execute)
        clean_name = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
        target_dir = scope.to_sym == :global ? global_tools_dir : project_tools_dir
        FileUtils.mkdir_p(target_dir)

        file_path = File.join(target_dir, "#{clean_name}.rb")
        schema_json = params_schema ? JSON.dump(params_schema) : "{}"
        header = <<~RUBY
          # frozen_string_literal: true
          # Rubik Custom Tool: #{clean_name}
          # Scope: #{scope}
          # Risk: #{risk}
          # Description: #{description}
          # Schema: #{schema_json}

        RUBY

        File.write(file_path, "#{header}#{code.strip}\n")
        { ok: true, path: file_path, name: clean_name, scope: scope }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def list_tools
        tools = []
        Dir.glob(File.join(global_tools_dir, "*.rb")).each do |f|
          name = File.basename(f, ".rb")
          tools << { name: name, scope: :global, path: f }
        end
        Dir.glob(File.join(project_tools_dir, "*.rb")).each do |f|
          name = File.basename(f, ".rb")
          tools << { name: name, scope: :project, path: f }
        end
        tools
      end

      def load_tools(tool_registry)
        loaded = []
        list_tools.each do |t_meta|
          code = File.read(t_meta[:path])
          tool_inst = eval_tool(t_meta[:name], code, t_meta[:scope])
          if tool_inst
            tool_registry.register(tool_inst)
            loaded << t_meta[:name]
          end
        rescue StandardError
          # log and continue
        end
        loaded
      end

      def eval_tool(name, code, scope)
        desc_match = code.match(/# Description:\s*(.*)/)
        description = desc_match ? desc_match[1].strip : "Custom #{scope} tool"

        schema_match = code.match(/# Schema:\s*(.*)/)
        schema = if schema_match
                   begin
                     JSON.parse(schema_match[1])
                   rescue
                     {}
                   end
                 else
                   {}
                 end

        risk_match = code.match(/# Risk:\s*(.*)/)
        risk = risk_match ? risk_match[1].strip.to_sym : :execute

        evaluated = eval(code) # rubocop:disable Security/Eval -- overlay özelliginin çekirdegi
        if evaluated.is_a?(Class) && evaluated < Rubik::Tools::BaseTool
          evaluated.new
        elsif evaluated.respond_to?(:call)
          Class.new(Rubik::Tools::BaseTool) do
            define_method(:initialize) do
              super(name: name, description: "#{description} [#{scope}]", risk: risk, params_schema: schema)
              @handler = evaluated
            end

            define_method(:execute) do |args = {}|
              @handler.call(args)
            end
          end.new
        end
      end
    end
  end
end
