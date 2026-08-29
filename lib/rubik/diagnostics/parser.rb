# frozen_string_literal: true

require_relative "entry"

module Rubik
  module Diagnostics
    class Parser
      def self.parse(output, lang = :unknown)
        new.parse(output, lang)
      end

      def parse(output, lang = :unknown)
        text = output.to_s
        return [Entry.new(message: "Empty compiler output", category: :unknown)] if text.strip.empty?

        entries = []
        entries = case lang.to_sym
                  when :ruby
                    parse_ruby(text)
                  when :go
                    parse_go(text)
                  when :rust
                    parse_rust(text)
                  when :zig, :c
                    parse_zig_c(text)
                  else
                    parse_generic(text)
                  end

        entries.empty? ? [Entry.new(message: text, category: :unknown, raw_text: text)] : entries
      rescue StandardError => e
        [Entry.new(message: "Parsing failed: #{e.message}\nRaw: #{text}", category: :unknown, raw_text: text)]
      end

      private

      def parse_ruby(text)
        entries = []
        text.each_line do |line|
          if (m = line.match(/^([^:]+):(\d+): (syntax error, unexpected .*)$/))
            entries << Entry.new(file: m[1], line: m[2], message: m[3], category: :syntax, raw_text: line)
          elsif (m = line.match(/Failure:\s*([^\n]+)/))
            entries << Entry.new(message: m[1], category: :test_failure, raw_text: line)
          end
        end
        entries
      end

      def parse_go(text)
        entries = []
        text.each_line do |line|
          if (m = line.match(/^([^:]+):(\d+):(\d+):\s*(undefined:\s*.*)$/))
            entries << Entry.new(file: m[1], line: m[2], col: m[3], message: m[4], category: :undefined_ref, raw_text: line)
          elsif (m = line.match(/^([^:]+):(\d+):(\d+):\s*(.*)$/))
            entries << Entry.new(file: m[1], line: m[2], col: m[3], message: m[4], category: :syntax, raw_text: line)
          end
        end
        entries
      end

      def parse_rust(text)
        entries = []
        current_error = nil

        text.each_line do |line|
          if (m = line.match(/^error\[(E\d+)\]:\s*(.*)$/))
            current_error = { code: m[1], message: m[2], category: :type }
          elsif current_error && (m = line.match(/-->\s*([^:]+):(\d+):(\d+)/))
            entries << Entry.new(
              file: m[1],
              line: m[2],
              col: m[3],
              code: current_error[:code],
              message: current_error[:message],
              category: current_error[:category],
              raw_text: line
            )
            current_error = nil
          end
        end
        entries
      end

      def parse_zig_c(text)
        entries = []
        text.each_line do |line|
          next unless (m = line.match(/^([^:]+):(\d+):(\d+):\s*error:\s*(.*)$/))

          msg = m[4]
          cat = msg.include?("undeclared identifier") || msg.include?("use of undeclared") ? :undefined_ref : :syntax
          entries << Entry.new(file: m[1], line: m[2], col: m[3], message: msg, category: cat, raw_text: line)
        end
        entries
      end

      def parse_generic(text)
        entries = []
        text.each_line do |line|
          if (m = line.match(/^([^:\s]+):(\d+):(?:\d+:)?\s*(.*)$/))
            entries << Entry.new(file: m[1], line: m[2], message: m[3], category: :unknown, raw_text: line)
          end
        end
        entries
      end
    end
  end
end
