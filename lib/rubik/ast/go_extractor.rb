# frozen_string_literal: true

require_relative "symbol"
require_relative "base_extractor"

module Rubik
  module AST
    class GoExtractor
      include BaseExtractor

      def extract
        symbols = []
        return symbols if @content.empty?

        i = 0
        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          stripped = line.strip

          if stripped.start_with?("import ")
            sym, i = parse_import(stripped, line_num, i)
            symbols << sym
          elsif (match = stripped.match(/^type\s+([A-Za-z0-9_]+)\s+(struct|interface)\b/))
            symbols << parse_type(match, line_num, i)
          elsif (match = stripped.match(/^func\s+(?:\(([A-Za-z0-9_*\s]+)\)\s+)?([A-Za-z0-9_]+)\s*\((.*?)\)/))
            symbols << parse_func(line, match, line_num, i)
          end

          i += 1
        end

        symbols
      end

      private

      def parse_import(stripped, line_num, index)
        if stripped.include?("(")
          end_line = find_closing_paren(index)
          symbol = Symbol.new(
            name: "import (...)",
            kind: :import,
            file: @file_path,
            line_start: line_num,
            line_end: end_line,
            signature: "import (...)"
          )
          [symbol, end_line - 1]
        else
          symbol = Symbol.new(
            name: stripped,
            kind: :import,
            file: @file_path,
            line_start: line_num,
            line_end: line_num,
            signature: stripped
          )
          [symbol, index]
        end
      end

      def parse_type(match, line_num, index)
        name = match[1]
        kind = match[2] == "struct" ? :struct : :interface
        end_line = find_closing_brace(index)
        Symbol.new(
          name: name,
          kind: kind,
          file: @file_path,
          line_start: line_num,
          line_end: end_line,
          signature: "type #{name} #{match[2]}",
          body_loader: body_loader_for(line_num, end_line)
        )
      end

      def parse_func(line, match, line_num, index)
        receiver = match[1]&.strip
        fn_name = match[2].strip
        full_name = receiver ? "(#{receiver}).#{fn_name}" : fn_name
        end_line = find_closing_brace(index)
        body_for_calls = extract_lines(line_num, end_line)
        calls = extract_calls(body_for_calls, fn_name)

        Symbol.new(
          name: full_name,
          kind: :function,
          file: @file_path,
          line_start: line_num,
          line_end: end_line,
          signature: line.split("{").first.to_s.strip,
          calls: calls,
          body_loader: body_loader_for(line_num, end_line)
        )
      end

      def extract_calls(body, self_name)
        calls = body.scan(/\b([A-Za-z0-9_]+)\s*\(/).flatten.uniq
        calls.reject { |c| c == self_name || ["func", "if", "for", "return", "make", "append", "len", "cap", "panic", "recover"].include?(c) }
      end

      def find_closing_paren(start_idx)
        (start_idx..(@lines.size - 1)).each do |idx|
          return idx + 1 if @lines[idx].include?(")")
        end
        start_idx + 1
      end
    end
  end
end
