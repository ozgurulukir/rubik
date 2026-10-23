# frozen_string_literal: true

require "shellwords"
require_relative "../platform"

module Rubik
  module LSP
    # Converts configured LSP commands to argv without invoking a shell.
    # Structured commands are portable; legacy strings use the native
    # platform's command-line quoting rules.
    module ServerCommand
      module_function

      def argv(command)
        parts = case command
                when Hash
                  executable = command["executable"] || command[:executable]
                  args = command["args"] || command[:args] || []
                  raise ArgumentError, "LSP command executable must be a non-empty string" unless executable.is_a?(String) && !executable.strip.empty?
                  raise ArgumentError, "LSP command args must be an array" unless args.is_a?(Array)
                  raise ArgumentError, "LSP command args must contain only strings" unless args.all? { |arg| arg.is_a?(String) }

                  [executable, *args]
                when Array
                  raise ArgumentError, "LSP argv must contain only strings" unless command.all? { |arg| arg.is_a?(String) }

                  command
                when String
                  Rubik::Platform.windows? ? split_windows(command) : Shellwords.shellsplit(command)
                else
                  []
                end

        parts = parts.map(&:to_s)
        return [] if parts.empty? || parts.first.to_s.strip.empty?
        raise ArgumentError, "LSP command arguments cannot be nil" if parts.any?(&:empty?)

        parts
      rescue ArgumentError => e
        raise ArgumentError, "Invalid LSP server command: #{e.message}"
      end

      def display(command)
        argv(command).join(" ")
      rescue ArgumentError
        command.to_s
      end

      # Implements the Windows command-line quoting rules used by
      # CommandLineToArgvW: backslashes only escape quotes when immediately
      # preceding one; whitespace separates arguments outside quotes.
      def split_windows(command)
        args = []
        arg = +""
        arg_started = false
        quoted = false
        i = 0

        while i < command.length
          if command[i] == "\\"
            start = i
            i += 1 while command[i] == "\\"
            slashes = i - start
            arg_started = true
            if command[i] == '"'
              arg << ("\\" * (slashes / 2))
              if slashes.odd?
                arg << '"'
              else
                quoted = !quoted
              end
              i += 1
            else
              arg << ("\\" * slashes)
            end
          elsif command[i] == '"'
            arg_started = true
            quoted = !quoted
            i += 1
          elsif command[i] =~ /\s/ && !quoted
            if arg_started
              args << arg
              arg = +""
              arg_started = false
            end
            i += 1 while command[i] =~ /\s/
          else
            arg_started = true
            arg << command[i]
            i += 1
          end
        end

        raise ArgumentError, "unmatched quote" if quoted
        args << arg if arg_started
        args
      end
      private_class_method :split_windows
    end
  end
end
