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
                  when :zig, :c, :cpp, :"c++", :cxx
                    parse_zig_c(text)
                  when :python, :py
                    parse_python(text)
                  when :typescript, :javascript, :ts, :js
                    parse_ts_js(text)
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
          next unless (m = line.match(/^([^:]+):(\d+):(\d+):(.*)$/))

          msg = m[4].strip
          cat = msg.start_with?("undefined:") ? :undefined_ref : :syntax
          entries << Entry.new(file: m[1], line: m[2], col: m[3], message: msg, category: cat, raw_text: line)
        end
        entries
      end

      def parse_rust(text)
        entries = []
        current_error = nil

        text.each_line do |line|
          if (m = line.match(/^error\[(E\d+)\]:(.*)$/))
            current_error = { code: m[1], message: m[2].strip, category: :type }
          elsif current_error && (m = line.match(/-->\s*([^:\s]+):(\d+):(\d+)/))
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
          next unless (m = line.match(/^([^:]+):(\d+):(\d+):\s*error:(.*)$/))

          msg = m[4].strip
          cat = msg.include?("undeclared identifier") || msg.include?("use of undeclared") ? :undefined_ref : :syntax
          entries << Entry.new(file: m[1], line: m[2], col: m[3], message: msg, category: cat, raw_text: line)
        end
        entries
      end

      def parse_python(text)
        entries = []
        current_file = nil
        current_line = nil

        text.each_line do |line|
          if (m = line.match(/File "([^"]+)", line (\d+)(?:, in .*)?/))
            current_file = m[1]
            current_line = m[2].to_i
          elsif (m = line.match(/^([A-Za-z0-9_]+Error|Exception):(.*)$/))
            cat = m[1] =~ /\A(?:Syntax|Indentation|Tab)Error\z/ ? :syntax : :type
            entries << Entry.new(
              file: current_file,
              line: current_line,
              message: "#{m[1]}: #{m[2].strip}",
              category: cat,
              raw_text: line
            )
            current_file = nil
            current_line = nil
          end
        end
        entries.empty? ? parse_generic(text) : entries
      end

      def parse_ts_js(text)
        entries = []
        text.each_line do |line|
          next unless (m = line.match(%r{^((?:[a-zA-Z]:[\\/])?[^(:\s]+)(?:\((\d+),(\d+)\)|:(\d+):(\d+))(?::\s*-\s*|:\s*|\s*-\s*|\s+)error(?:\s+(TS\d+))?:?(.*)$}i))

          file = m[1]
          line_num = (m[2] || m[4]).to_i
          col_num = (m[3] || m[5]).to_i
          code = m[6]
          msg = m[7].strip
          entries << Entry.new(
            file: file,
            line: line_num,
            col: col_num,
            code: code,
            message: msg,
            category: :syntax,
            raw_text: line
          )
        end
        entries.empty? ? parse_generic(text) : entries
      end

      def parse_generic(text)
        entries = []
        text.each_line do |line|
          if (m = line.match(/^([^:\s]+):(\d+):(?:\d+:)?(.*)$/))
            entries << Entry.new(file: m[1], line: m[2], message: m[3].strip, category: :unknown, raw_text: line)
          end
        end
        entries
      end
    end
  end
end
