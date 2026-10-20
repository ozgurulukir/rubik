# frozen_string_literal: true

require_relative "symbol"
require_relative "base_extractor"

module Rubik
  module AST
    class TypeScriptExtractor
      include BaseExtractor

      def extract
        # rubocop:disable Lint/DuplicateBranch -- ayri predikat'lar ayni govdeyi tasir: her parse_* farkli satir seklini yakalar
        symbols = []
        return symbols if @content.empty?

        current_class = nil
        class_end_line = 0
        i = 0

        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          stripped = line.strip

          current_class = nil if line_num > class_end_line

          if (res = parse_import(stripped, line_num, i))
            sym, i = res
            symbols << sym
          elsif (res = parse_class(line, stripped, line_num, i))
            sym, current_class, class_end_line = res
            symbols << sym
          elsif (sym = parse_interface(line, stripped, line_num, i))
            symbols << sym
          elsif (res = parse_type(line, stripped, line_num, i))
            sym, i = res
            symbols << sym
          elsif (res = parse_function(line, stripped, line_num, i))
            sym, i = res
            symbols << sym
          elsif current_class && (res = parse_method(line, stripped, line_num, i, current_class))
            sym, i = res
            symbols << sym
          end

          i += 1
        end

        symbols
        # rubocop:enable Lint/DuplicateBranch
      end

      private

      def parse_import(stripped, line_num, idx)
        if stripped.start_with?("import ") || stripped.start_with?("import{") || stripped.match?(/^import\s+type\s+/)
          if stripped.include?(";") ||
             (stripped.include?("from") && (stripped.end_with?("'") || stripped.end_with?('"') ||
              stripped.end_with?("';") || stripped.end_with?('";')))
            sym = Symbol.new(
              name: stripped.sub(/;$/, ""),
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
            [sym, idx]
          else
            end_line = find_import_end(idx)
            full_sig = @lines[idx..(end_line - 1)].map(&:strip).join(" ")
            sym = Symbol.new(
              name: full_sig.sub(/;$/, ""),
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: full_sig
            )
            [sym, end_line - 1]
          end
        elsif (stripped.start_with?("export ") && stripped.include?(" from ")) ||
              stripped.match?(/^(?:const|let|var)\s+([A-Za-z0-9_$]+)\s*=\s*require\((.*?)\)/)
          sym = Symbol.new(
            name: stripped.sub(/;$/, ""),
            kind: :import,
            file: @file_path,
            line_start: line_num,
            line_end: line_num,
            signature: stripped
          )
          [sym, idx]
        end
      end

      def parse_class(line, stripped, line_num, idx)
        return unless (match = stripped.match(/^(?:export\s+(?:default\s+)?)?(?:abstract\s+)?class\s+([A-Za-z0-9_$]+)/))

        class_name = match[1]
        class_end_line = find_closing_brace(idx)

        sym = Symbol.new(
          name: class_name,
          kind: :class,
          file: @file_path,
          line_start: line_num,
          line_end: class_end_line,
          signature: line.split("{").first.to_s.strip,
          body_loader: body_loader_for(line_num, class_end_line)
        )
        [sym, class_name, class_end_line]
      end

      def parse_interface(line, stripped, line_num, idx)
        return unless (match = stripped.match(/^(?:export\s+)?interface\s+([A-Za-z0-9_$]+)/))

        if_name = match[1]
        end_line = find_closing_brace(idx)

        Symbol.new(
          name: if_name,
          kind: :interface,
          file: @file_path,
          line_start: line_num,
          line_end: end_line,
          signature: line.split("{").first.to_s.strip,
          body_loader: body_loader_for(line_num, end_line)
        )
      end

      def parse_type(line, stripped, line_num, idx)
        return unless (match = stripped.match(/^(?:export\s+)?type\s+([A-Za-z0-9_$]+)/))

        type_name = match[1]
        end_line = stripped.include?("{") ? find_closing_brace(idx) : find_statement_end(idx)

        sym = Symbol.new(
          name: type_name,
          kind: :type,
          file: @file_path,
          line_start: line_num,
          line_end: end_line,
          signature: line.split(/[{=]/).first.to_s.strip,
          body_loader: body_loader_for(line_num, end_line)
        )
        next_i = end_line > line_num ? end_line - 1 : idx
        [sym, next_i]
      end

      def parse_function(line, stripped, line_num, idx)
        if (match = stripped.match(/^(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*(?:\*\s*)?([A-Za-z0-9_$]+)?\s*\(/))
          fn_name = match[1] || "default"
          end_line = stripped.include?("{") ? find_closing_brace(idx) : find_statement_end(idx)
          body_for_calls = extract_lines(line_num, end_line)
          calls = extract_calls(body_for_calls, fn_name)

          sym = Symbol.new(
            name: fn_name,
            kind: :function,
            file: @file_path,
            line_start: line_num,
            line_end: end_line,
            signature: line.split("{").first.to_s.strip,
            calls: calls,
            body_loader: body_loader_for(line_num, end_line)
          )
          next_i = end_line > line_num ? end_line - 1 : idx
          [sym, next_i]
        elsif (match = stripped.match(
          /^(?:export\s+)?(?:const|let|var)\s+([A-Za-z0-9_$]+)(?:\s*:\s*[^=]+)?\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z0-9_$]+)\s*=>/
        )) ||
              (match = stripped.match(/^(?:export\s+)?(?:const|let|var)\s+([A-Za-z0-9_$]+)\s*=\s*(?:async\s*)?function\b/))
          fn_name = match[1]
          end_line = stripped.include?("{") ? find_closing_brace(idx) : find_statement_end(idx)
          body_for_calls = extract_lines(line_num, end_line)
          calls = extract_calls(body_for_calls, fn_name)

          sym = Symbol.new(
            name: fn_name,
            kind: :function,
            file: @file_path,
            line_start: line_num,
            line_end: end_line,
            signature: line.split("=>").first.to_s.strip.sub(/=\s*$/, "").strip,
            calls: calls,
            body_loader: body_loader_for(line_num, end_line)
          )
          next_i = end_line > line_num ? end_line - 1 : idx
          [sym, next_i]
        end
      end

      def parse_method(line, stripped, line_num, idx, current_class)
        return unless (match = stripped.match(
          /^(?:(?:public|private|protected|static|async|get|set)\s+)*([A-Za-z0-9_$]+)\s*\([^)]*\)(?:\s*:\s*[^{]+)?\s*\{/
        ))

        method_name = match[1]
        return if ["if", "for", "while", "switch", "catch", "function"].include?(method_name)

        full_name = "#{current_class}##{method_name}"
        end_line = find_closing_brace(idx)
        body = extract_lines(line_num, end_line)
        calls = extract_calls(body, method_name)

        sym = Symbol.new(
          name: full_name,
          kind: :function,
          file: @file_path,
          line_start: line_num,
          line_end: end_line,
          signature: line.split("{").first.to_s.strip,
          calls: calls,
          body_loader: body_loader_for(line_num, end_line)
        )
        next_i = end_line > line_num ? end_line - 1 : idx
        [sym, next_i]
      end

      def extract_calls(body, self_name)
        calls = body.scan(/\b([A-Za-z0-9_$]+)\s*\(/).flatten.uniq
        keywords = [
          "if", "else", "for", "while", "do", "switch", "case", "return", "catch", "function", "import",
          "require", "typeof", "instanceof", "throw", "new", "try", "finally", "delete", "void", "yield",
          "await", "super", "class", "interface", "type", "const", "let", "var"
        ]
        calls.reject { |c| c == self_name || keywords.include?(c) }
      end

      def find_statement_end(start_idx)
        (start_idx..(@lines.size - 1)).each do |idx|
          return idx + 1 if @lines[idx].include?(";")
        end
        start_idx + 1
      end

      def find_import_end(start_idx)
        (start_idx..(@lines.size - 1)).each do |idx|
          line = @lines[idx]
          return idx + 1 if line.include?(";") || line.include?("from ") || line.include?("from'") || line.include?('from"')
        end
        start_idx + 1
      end
    end
  end
end
