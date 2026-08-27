# frozen_string_literal: true

require_relative "symbol"
require_relative "body_loader"

module Rubik
  module AST
    class GoExtractor
      include BodyLoader

      def self.extract(file_path, content = nil)
        new(file_path, content).extract
      end

      def initialize(file_path, content = nil)
        @file_path = file_path
        @content = content || (File.exist?(file_path) ? File.read(file_path) : "")
        @lines = @content.lines
      end

      def extract
        symbols = []
        return symbols if @content.empty?

        i = 0
        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          stripped = line.strip

          if stripped.start_with?("import ")
            if stripped.include?("(")
              end_line = find_closing_paren(i)
              symbols << Symbol.new(
                name: "import (...)",
                kind: :import,
                file: @file_path,
                line_start: line_num,
                line_end: end_line,
                signature: "import (...)"
              )
              i = end_line - 1
            else
              symbols << Symbol.new(
                name: stripped,
                kind: :import,
                file: @file_path,
                line_start: line_num,
                line_end: line_num,
                signature: stripped
              )
            end
          elsif (match = stripped.match(/^type\s+([A-Za-z0-9_]+)\s+(struct|interface)\b/))
            name = match[1]
            kind = match[2] == "struct" ? :struct : :interface
            end_line = find_closing_brace(i)
            symbols << Symbol.new(
              name: name,
              kind: kind,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: "type #{name} #{match[2]}",
              body_loader: body_loader_for(line_num, end_line)
            )
          elsif (match = stripped.match(/^func\s+(?:\(([A-Za-z0-9_\*\s]+)\)\s+)?([A-Za-z0-9_]+)\s*\((.*?)\)/))
            receiver = match[1]&.strip
            fn_name = match[2].strip
            full_name = receiver ? "(#{receiver}).#{fn_name}" : fn_name
            end_line = find_closing_brace(i)
            body_for_calls = extract_lines(line_num, end_line)
            calls = extract_calls(body_for_calls, fn_name)

            symbols << Symbol.new(
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

          i += 1
        end

        symbols
      end

      private

      def extract_calls(body, self_name)
        calls = body.scan(/\b([A-Za-z0-9_]+)\s*\(/).flatten.uniq
        calls.reject { |c| c == self_name || %w[func if for return make append len cap panic recover].include?(c) }
      end

      def find_closing_brace(start_idx)
        brace_count = 0
        found_open = false

        (start_idx..@lines.size - 1).each do |idx|
          line = @lines[idx]
          line.each_char do |char|
            if char == "{"
              brace_count += 1
              found_open = true
            elsif char == "}"
              brace_count -= 1
            end
          end

          return idx + 1 if found_open && brace_count <= 0
        end

        start_idx + 1
      end

      def find_closing_paren(start_idx)
        (start_idx..@lines.size - 1).each do |idx|
          return idx + 1 if @lines[idx].include?(")")
        end
        start_idx + 1
      end

      def extract_lines(start_line, end_line)
        s_idx = [start_line - 1, 0].max
        e_idx = [end_line - 1, @lines.size - 1].min
        @lines[s_idx..e_idx].join
      end
    end
  end
end
