# frozen_string_literal: true

require "shellwords"

module Rubik
  module REPL
    class CommandParser
      ParsedInput = Struct.new(:type, :command_name, :args, :raw, keyword_init: true)

      def self.parse(input)
        new.parse(input)
      end

      def parse(input)
        raw_text = input.to_s.strip
        return ParsedInput.new(type: :empty, raw: raw_text) if raw_text.empty?

        if raw_text.start_with?("!")
          parse_command(raw_text)
        else
          ParsedInput.new(type: :prompt, raw: raw_text)
        end
      end

      def parse_args(arg_string)
        Shellwords.split(arg_string.to_s)
      rescue ArgumentError
        arg_string.to_s.split
      end

      private

      def parse_command(text)
        parts = text[1..].strip.split(/\s+/, 2)
        cmd_name = parts[0] ? parts[0].downcase : ""
        arg_str = parts[1] || ""
        args = parse_args(arg_str)

        ParsedInput.new(
          type: :command,
          command_name: cmd_name,
          args: args,
          raw: text
        )
      end
    end
  end
end
