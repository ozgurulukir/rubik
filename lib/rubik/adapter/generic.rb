# frozen_string_literal: true

require "shellwords"
require_relative "base"
require_relative "../security/guard" unless defined?(Rubik::Security::Guard)

module Rubik
  module Adapter
    class GenericAdapter < BaseAdapter
      attr_accessor :custom_syntax_cmd

      def initialize(name, binary_name: nil, test_cmd: nil, format_cmd: nil, syntax_cmd: nil)
        validate_custom_command!(test_cmd) if test_cmd
        validate_custom_command!(format_cmd) if format_cmd
        validate_custom_command!(syntax_cmd) if syntax_cmd

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

      # Validate a custom command string through the Security::Guard before it
      # is ever executed. These commands are operator-supplied arbitrary shell
      # commands; running them without classification is the exact RCE surface
      # this adapter used to expose. Fail-closed: an unclassifiable or dangerous
      # string raises BlockedWriteError rather than running.
      def validate_custom_command!(cmd_str, shell: nil)
        return true if cmd_str.nil? || cmd_str.to_s.strip.empty?

        Rubik::Security::Guard.new(audit_log_path: nil).verify_command_safety!(cmd_str, shell: shell)
        true
      end

      def available?
        Runtime::Discovery.binary_available?(@binary_name)
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        return { ok: true, output: "Syntax check not configured for #{@name}", duration: 0.0, exit_code: 0 } unless @custom_syntax_cmd

        # Classify + validate the operator-supplied syntax command through the
        # Security::Guard before executing it (no bare process run).
        validate_custom_command!(@custom_syntax_cmd, shell: nil)

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
