# frozen_string_literal: true

require "shellwords"
require_relative "process"
require_relative "../platform"
require_relative "../runtime/discovery"
require_relative "../runtime/diagnostic_engine"

module Rubik
  module Adapter
    class BaseAdapter
      attr_reader :name, :binary_name
      attr_accessor :custom_test_cmd, :custom_format_cmd, :config

      def initialize(name, binary_name)
        @name = name.to_s.downcase
        @binary_name = binary_name
        @custom_test_cmd = nil
        @custom_format_cmd = nil
        @config = nil
      end

      def available?
        !Rubik::Platform.which(@binary_name).nil?
      end

      def check_syntax(_file_path)
        return unavailable_result unless available?

        raise NotImplementedError
      end

      # Compilation is an optional capability: interpreted languages ride this
      # no-op default and only compiled-language adapters override it.
      def compile(_root_dir)
        { ok: true, output: "#{@name} requires no compilation", duration: 0.0, exit_code: 0 }
      end

      def run_tests(root_dir)
        return unavailable_result unless available?

        cmd = resolve_test_cmd(root_dir)
        unless cmd && Runtime::Discovery.binary_available?(cmd)
          candidates = if @config
                         Runtime::Discovery.test_runner_candidates(@name, root_dir: root_dir, config: @config)
                       else
                         Runtime::Discovery.test_runner_candidates(@name, root_dir: root_dir)
                       end
          reason = if candidates.any?
                     "No test runner found for #{@name} (tried: #{candidates.join(', ')}). Install one or set custom_test_cmd."
                   else
                     "No test runner found for #{@name}. Install one or set custom_test_cmd."
                   end
          return unavailable_result(reason: reason)
        end

        res = ProcessRunner.run(cmd, chdir: root_dir)
        res[:diagnostic] = Runtime::DiagnosticEngine.analyze_process_result(res, cmd: cmd) unless res[:ok]
        res
      end

      def format_code(file_path)
        cmd = resolve_format_cmd(file_path)
        return unavailable_result unless cmd && Runtime::Discovery.binary_available?(cmd)

        res = ProcessRunner.run(cmd)
        res[:diagnostic] = Runtime::DiagnosticEngine.analyze_process_result(res, cmd: cmd) unless res[:ok]
        res
      end

      def resolve_test_cmd(root_dir = Dir.pwd)
        return @custom_test_cmd if @custom_test_cmd && !@custom_test_cmd.strip.empty?

        discovered = if @config
                       Runtime::Discovery.discover_test_runners(root_dir: root_dir, lang: @name, config: @config)
                     else
                       Runtime::Discovery.discover_test_runners(root_dir: root_dir, lang: @name)
                     end
        discovered.first || default_test_cmd
      end

      def resolve_format_cmd(file_path)
        if @custom_format_cmd && !@custom_format_cmd.strip.empty?
          if @custom_format_cmd.include?("%s")
            format(@custom_format_cmd, Shellwords.escape(file_path))
          else
            "#{@custom_format_cmd} #{Shellwords.escape(file_path)}"
          end
        else
          discovered = Runtime::Discovery.discover_formatters(root_dir: File.dirname(file_path), lang: @name)
          if discovered.first
            "#{discovered.first} #{Shellwords.escape(file_path)}"
          else
            default_format_cmd(file_path)
          end
        end
      end

      protected

      def default_test_cmd
        nil
      end

      def default_format_cmd(_file_path)
        nil
      end

      def unavailable_result(binary = nil, reason: nil)
        bin = binary || @binary_name
        msg = reason || "#{bin} is unavailable on system"
        { ok: false, output: msg, duration: 0.0, exit_code: 127 }
      end
    end
  end
end
