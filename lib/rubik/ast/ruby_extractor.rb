# frozen_string_literal: true

require_relative "symbol"

module Rubik
  module AST
    class RubyExtractor
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

        current_class_or_module = nil
        i = 0

        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          stripped = line.strip

          if stripped.start_with?("class ") || stripped.start_with?("module ")
            kind = stripped.start_with?("class ") ? :class : :module
            name = stripped.split(/\s+/)[1].to_s.split("<").first.to_s.strip
            current_class_or_module = name
            end_line = find_matching_end(i)

            symbols << Symbol.new(
              name: name,
              kind: kind,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: stripped
            )
          elsif stripped.start_with?("def ")
            method_name = stripped.sub(/^def\s+/, "").split(/[\(\s;]/).first.strip
            full_name = current_class_or_module ? "#{current_class_or_module}##{method_name}" : method_name
            end_line = find_matching_end(i)
            body = extract_body(i, end_line)
            calls = extract_calls_from_body(body, method_name)

            symbols << Symbol.new(
              name: full_name,
              kind: :function,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: stripped,
              calls: calls,
              body: body
            )
          elsif stripped.start_with?("require ") || stripped.start_with?("require_relative ")
            symbols << Symbol.new(
              name: stripped,
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
          end

          i += 1
        end

        symbols
      end

      private

      def find_matching_end(start_idx)
        depth = 0
        (start_idx..@lines.size - 1).each do |idx|
          line = @lines[idx].strip
          next if line.start_with?("#")

          tokens = line.scan(/\b(class|module|def|do|if|unless|case|end)\b/)
          tokens.each do |t|
            keyword = t.first
            if keyword == "end"
              depth -= 1
            else
              depth += 1
            end
          end

          return idx + 1 if depth <= 0 && idx >= start_idx
        end
        start_idx + 1
      end

      def extract_calls_from_body(body, self_name)
        calls = body.scan(/\b([a-z_][a-zA-Z0-9_]*)\s*\(/).flatten.uniq
        calls.reject { |c| c == self_name || %w[def if unless case return raise puts p print require].include?(c) }
      end

      def extract_body(start_idx, end_idx)
        start_line = [start_idx, 0].max
        end_line = [end_idx - 1, @lines.size - 1].min
        @lines[start_line..end_line].join
      end
    end
  end
end
