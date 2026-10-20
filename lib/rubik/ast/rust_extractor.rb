# frozen_string_literal: true

require_relative "symbol"
require_relative "base_extractor"

module Rubik
  module AST
    class RustExtractor
      include BaseExtractor

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

            # De-duplicate: the same logical symbol must be emitted exactly once.
            # Without this guard an `impl Trait for X` block that also matched
            # the generic `fn` rule earlier could re-emit a method as a free
            # function, producing a duplicate-symbol collision in the graph.
            next if symbols.any? { |s| s.name == full_name }

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
        calls.reject { |c| c == self_name || ["fn", "pub", "async", "if", "for", "while", "loop", "match", "return", "let", "mut"].include?(c) }
      end
    end
  end
end
