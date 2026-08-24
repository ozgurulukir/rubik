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
      attr_accessor :custom_test_cmd, :custom_format_cmd

      def initialize(name, binary_name)
        @name = name.to_s.downcase
        @binary_name = binary_name
        @custom_test_cmd = nil
        @custom_format_cmd = nil
      end

      def available?
        !Rubik::Platform.which(@binary_name).nil?
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        raise NotImplementedError
      end

      def compile(root_dir)
        return unavailable_result unless available?
        raise NotImplementedError
      end

      def run_tests(root_dir)
        cmd = resolve_test_cmd(root_dir)
        return unavailable_result unless cmd && Runtime::Discovery.binary_available?(cmd)

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

        discovered = Runtime::Discovery.discover_test_runners(root_dir: root_dir, lang: @name)
        discovered.first || default_test_cmd
      end

      def resolve_format_cmd(file_path)
        if @custom_format_cmd && !@custom_format_cmd.strip.empty?
          if @custom_format_cmd.include?("%s")
            sprintf(@custom_format_cmd, Shellwords.escape(file_path))
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

      def unavailable_result(binary = nil)
        bin = binary || @binary_name
        { ok: false, output: "#{bin} is unavailable on system", duration: 0.0, exit_code: 127 }
      end
    end
  end
end
