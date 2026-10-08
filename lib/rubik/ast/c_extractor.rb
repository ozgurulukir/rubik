# frozen_string_literal: true

require "set"
require_relative "symbol"
require_relative "body_loader"

module Rubik
  module AST
    class CExtractor
      include BodyLoader

      EXCLUDED_CALLS = Set.new(["if", "for", "while", "switch", "return", "sizeof", "malloc", "free", "printf"]).freeze

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

          if stripped.start_with?("#include")
            symbols << Symbol.new(
              name: stripped,
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
          elsif (match = stripped.match(/^(?:typedef\s+)?(struct|union|enum)\s+([A-Za-z0-9_]+)?\s*\{?/))
            name = match[2] || "anonymous_#{kind}_#{line_num}"
            end_line = stripped.include?(";") && !stripped.include?("{") ? line_num : find_closing_brace(i)
            symbols << Symbol.new(
              name: name,
              kind: match[1].to_sym,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: line.split("{").first.to_s.strip,
              body_loader: body_loader_for(line_num, end_line)
            )
          elsif (match = stripped.match(/^([A-Za-z0-9_*\s]+)\s+([A-Za-z0-9_]+)\s*\((.*?)\)\s*\{/))
            fn_name = match[2]
            unless ["if", "for", "while", "switch"].include?(fn_name)
              end_line = find_closing_brace(i)
              body = extract_lines(line_num, end_line)
              calls = extract_calls(body, fn_name)

              symbols << Symbol.new(
                name: fn_name,
                kind: :function,
                file: @file_path,
                line_start: line_num,
                line_end: end_line,
                signature: line.split("{").first.to_s.strip,
                calls: calls,
                body_loader: body_loader_for(line_num, end_line)
              )
            end
          end

          i += 1
        end

        symbols
      end

      private

      def extract_calls(body, self_name)
        body.scan(/\b[A-Za-z0-9_]+(?=\s*\()/).uniq.delete_if { |c| c == self_name || EXCLUDED_CALLS.include?(c) }
      end

      def find_closing_brace(start_idx)
        brace_count = 0
        found_open = false

        (start_idx..(@lines.size - 1)).each do |idx|
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

      def extract_lines(start_line, end_line)
        s_idx = [start_line - 1, 0].max
        e_idx = [end_line - 1, @lines.size - 1].min
        @lines[s_idx..e_idx].join
      end
    end
  end
end
