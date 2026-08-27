# frozen_string_literal: true

require_relative "symbol"
require_relative "body_loader"

module Rubik
  module AST
    class RustExtractor
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

        current_impl = nil
        impl_end_line = 0
        i = 0

        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          stripped = line.strip

          current_impl = nil if line_num > impl_end_line

          if stripped.start_with?("use ")
            symbols << Symbol.new(
              name: stripped.sub(/;$/, ""),
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
          elsif (match = stripped.match(/^(?:pub(?:\(crate\))?\s+)?(struct|enum|trait)\s+([A-Za-z0-9_]+)/))
            kind = match[1].to_sym
            name = match[2]
            end_line = stripped.end_with?(";") ? line_num : find_closing_brace(i)
            symbols << Symbol.new(
              name: name,
              kind: kind,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: line.split("{").first.to_s.strip,
              body_loader: body_loader_for(line_num, end_line)
            )
          elsif (match = stripped.match(/^impl(?:\s*<.*?>)?\s+([A-Za-z0-9_]+(?:\s+for\s+[A-Za-z0-9_]+)?)/))
            current_impl = match[1].split(" for ").last.to_s.strip
            impl_end_line = find_closing_brace(i)
          elsif (match = stripped.match(/^(?:pub(?:\(crate\))?\s+)?(?:async\s+)?fn\s+([A-Za-z0-9_]+)\s*(?:<.*?>)?\s*\((.*?)\)/))
            fn_name = match[1]
            full_name = current_impl ? "#{current_impl}::#{fn_name}" : fn_name
            end_line = stripped.end_with?(";") ? line_num : find_closing_brace(i)
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
        calls = body.scan(/\b([A-Za-z0-9_]+)(?:!|\s*\()/).flatten.uniq
        calls.reject { |c| c == self_name || %w[fn pub async if for while loop match return let mut].include?(c) }
      end

      def find_closing_brace(start_idx)
        brace_count = 0
        found_open = false

        (start_idx..@lines.size - 1).each do |idx|
          line = @lines[idx]
          line.chars.each do |char|
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
