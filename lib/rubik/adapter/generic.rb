# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class GenericAdapter < BaseAdapter
      attr_accessor :custom_syntax_cmd

      def initialize(name, binary_name: nil, test_cmd: nil, format_cmd: nil, syntax_cmd: nil)
        derived_bin = binary_name ||
                      (test_cmd ? test_cmd.to_s.strip.split.first : nil) ||
                      (format_cmd ? format_cmd.to_s.strip.split.first : nil) ||
                      (syntax_cmd ? syntax_cmd.to_s.strip.split.first : nil) ||
                      name
        super(name, derived_bin)
        @custom_test_cmd = test_cmd
        @custom_format_cmd = format_cmd
        @custom_syntax_cmd = syntax_cmd
      end

      def available?
        Runtime::Discovery.binary_available?(@binary_name)
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        return { ok: true, output: "Syntax check not configured for #{@name}", duration: 0.0, exit_code: 0 } unless @custom_syntax_cmd

        cmd = if @custom_syntax_cmd.include?("%s")
                format(@custom_syntax_cmd, Shellwords.escape(file_path))
              else
                "#{@custom_syntax_cmd} #{Shellwords.escape(file_path)}"
              end
        ProcessRunner.run(cmd)
      end

      protected

      def default_test_cmd
        @custom_test_cmd
      end

      def default_format_cmd(file_path)
        return nil unless @custom_format_cmd

        if @custom_format_cmd.include?("%s")
          format(@custom_format_cmd, Shellwords.escape(file_path))
        else
          "#{@custom_format_cmd} #{Shellwords.escape(file_path)}"
        end
      end
    end
  end
end
