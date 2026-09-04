# frozen_string_literal: true

require "json"
require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class NodeAdapter < BaseAdapter
      def initialize(name = "node", binary_name = "node")
        super
      end

      def available?
        !Rubik::Platform.which("node").nil? ||
          !Rubik::Platform.which("npm").nil? ||
          !Rubik::Platform.which("bun").nil?
      end

      def resolve_test_cmd(root_dir = Dir.pwd)
        return @custom_test_cmd if @custom_test_cmd && !@custom_test_cmd.strip.empty?

        runner = runner_for(root_dir)
        pkg_file = File.join(root_dir, "package.json")

        if File.exist?(pkg_file)
          begin
            parsed = JSON.parse(File.read(pkg_file))
            scripts = parsed.is_a?(Hash) && parsed["scripts"].is_a?(Hash) ? parsed["scripts"] : {}

            target_script = if scripts.key?("test:run")
                              "test:run"
                            elsif scripts.key?("test")
                              "test"
                            elsif scripts.key?("test:unit")
                              "test:unit"
                            end

            if target_script
              return target_script == "test" ? "#{runner} test" : "#{runner} run #{target_script}"
            end
          rescue JSON::ParserError
            # fallback to default
          end
        end

        "#{runner} test"
      end

      def check_syntax(file_path)
        return unavailable_result unless available?

        ext = File.extname(file_path).downcase
        escaped = Shellwords.escape(file_path)

        cmd = case ext
              when ".ts", ".tsx"
                if Runtime::Discovery.binary_available?("tsc")
                  "tsc --noEmit #{escaped}"
                else
                  "npx tsc --noEmit #{escaped}"
                end
              when ".vue"
                if Runtime::Discovery.binary_available?("vue-tsc")
                  "vue-tsc --noEmit"
                else
                  "npx vue-tsc --noEmit"
                end
              else
                "node --check #{escaped}"
              end

        ProcessRunner.run(cmd)
      end

      def resolve_format_cmd(file_path)
        if @custom_format_cmd && !@custom_format_cmd.strip.empty?
          if @custom_format_cmd.include?("%s")
            format(@custom_format_cmd, Shellwords.escape(file_path))
          else
            "#{@custom_format_cmd} #{Shellwords.escape(file_path)}"
          end
        else
          escaped = Shellwords.escape(file_path)
          dir = File.dirname(file_path)
          discovered = Runtime::Discovery.discover_formatters(root_dir: dir, lang: @name)
          if discovered.first
            "#{discovered.first} #{escaped}"
          elsif Runtime::Discovery.binary_available?("biome")
            "biome format --write #{escaped}"
          elsif Runtime::Discovery.binary_available?("prettier")
            "prettier --write #{escaped}"
          else
            default_format_cmd(file_path)
          end
        end
      end

      protected

      def runner_for(root_dir)
        if File.exist?(File.join(root_dir, "pnpm-lock.yaml"))
          "pnpm"
        elsif File.exist?(File.join(root_dir, "yarn.lock"))
          "yarn"
        elsif File.exist?(File.join(root_dir, "bun.lockb"))
          "bun"
        else
          "npm"
        end
      end

      def default_test_cmd
        "npm test"
      end

      def default_format_cmd(file_path)
        "prettier --write #{Shellwords.escape(file_path)}"
      end
    end
  end
end
