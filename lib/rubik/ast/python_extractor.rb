# frozen_string_literal: true

require_relative "symbol"
require_relative "base_extractor"

module Rubik
  module AST
    class PythonExtractor
      include BaseExtractor

      EXCLUDED_KEYWORDS = Set.new(
        ["def", "async", "if", "elif", "else", "for", "while", "return", "print", "len", "range", "super"]
      ).freeze

      def extract
        symbols = []
        return symbols if @content.empty?

        current_class = nil
        i = 0

        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          indent = line[/^\s*/].size
          stripped = line.strip

          if stripped.start_with?("import ") || stripped.start_with?("from ")
            symbols << Symbol.new(
              name: stripped,
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
          elsif (match = stripped.match(/^class\s+([A-Za-z0-9_]+)(?:\((.*?)\))?:/))
            class_name = match[1]
            current_class = class_name
            end_line = find_block_end(i, indent)
            symbols << Symbol.new(
              name: class_name,
              kind: :class,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: stripped,
              body_loader: body_loader_for(line_num, end_line)
            )
          elsif (match = stripped.match(/^(?:async\s+)?def\s+([A-Za-z0-9_]+)\s*\((.*?)\):/))
            fn_name = match[1]
            full_name = indent.positive? && current_class ? "#{current_class}.#{fn_name}" : fn_name
            end_line = find_block_end(i, indent)
            body_for_calls = extract_lines(line_num, end_line)
            calls = extract_calls(body_for_calls, fn_name)

            symbols << Symbol.new(
              name: full_name,
              kind: :function,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: stripped,
              calls: calls,
              body_loader: body_loader_for(line_num, end_line)
            )
          end

          current_class = nil if indent.zero? && !stripped.start_with?("class ") && !stripped.empty?

          i += 1
        end

        symbols
      end

      private

      def extract_calls(body, self_name)
        calls = Set.new
        body.scan(/\b[A-Za-z0-9_]+(?=\s*\()/) do |c|
          calls << c unless c == self_name || EXCLUDED_KEYWORDS.include?(c)
        end
        calls.to_a
      end

      def find_block_end(start_idx, base_indent)
        last_line = start_idx + 1

        ((start_idx + 1)..(@lines.size - 1)).each do |idx|
          line = @lines[idx]
          next if line.strip.empty? || line.strip.start_with?("#")

          indent = line[/^\s*/].size
          return last_line if indent <= base_indent

          last_line = idx + 1
        end

        @lines.size
      end
    end
  end
end
