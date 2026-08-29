# frozen_string_literal: true

require_relative "symbol"
require_relative "body_loader"

module Rubik
  module AST
    class TypeScriptExtractor
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

        current_class = nil
        class_end_line = 0
        i = 0

        while i < @lines.size
          line = @lines[i]
          line_num = i + 1
          stripped = line.strip

          current_class = nil if line_num > class_end_line

          if stripped.start_with?("import ") || stripped.start_with?("import{") || stripped.match?(/^import\s+type\s+/)
            if stripped.include?(";") ||
               (stripped.include?("from") && (stripped.end_with?("'") || stripped.end_with?('"') ||
                stripped.end_with?("';") || stripped.end_with?('";')))
              symbols << Symbol.new(
                name: stripped.sub(/;$/, ""),
                kind: :import,
                file: @file_path,
                line_start: line_num,
                line_end: line_num,
                signature: stripped
              )
            else
              end_line = find_import_end(i)
              full_sig = @lines[i..end_line - 1].map(&:strip).join(" ")
              symbols << Symbol.new(
                name: full_sig.sub(/;$/, ""),
                kind: :import,
                file: @file_path,
                line_start: line_num,
                line_end: end_line,
                signature: full_sig
              )
              i = end_line - 1
            end
          elsif stripped.start_with?("export ") && stripped.include?(" from ")
            symbols << Symbol.new(
              name: stripped.sub(/;$/, ""),
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
          elsif (match = stripped.match(/^(?:export\s+(?:default\s+)?)?(?:abstract\s+)?class\s+([A-Za-z0-9_$]+)/))
            class_name = match[1]
            current_class = class_name
            class_end_line = find_closing_brace(i)

            symbols << Symbol.new(
              name: class_name,
              kind: :class,
              file: @file_path,
              line_start: line_num,
              line_end: class_end_line,
              signature: line.split("{").first.to_s.strip,
              body_loader: body_loader_for(line_num, class_end_line)
            )
          elsif (match = stripped.match(/^(?:export\s+)?interface\s+([A-Za-z0-9_$]+)/))
            if_name = match[1]
            end_line = find_closing_brace(i)

            symbols << Symbol.new(
              name: if_name,
              kind: :interface,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: line.split("{").first.to_s.strip,
              body_loader: body_loader_for(line_num, end_line)
            )
          elsif (match = stripped.match(/^(?:export\s+)?type\s+([A-Za-z0-9_$]+)/))
            type_name = match[1]
            end_line = stripped.include?("{") ? find_closing_brace(i) : find_statement_end(i)

            symbols << Symbol.new(
              name: type_name,
              kind: :type,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: line.split(/[{=]/).first.to_s.strip,
              body_loader: body_loader_for(line_num, end_line)
            )
            i = end_line - 1 if end_line > line_num
          elsif (match = stripped.match(/^(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*(?:\*\s*)?([A-Za-z0-9_$]+)?\s*\(/))
            fn_name = match[1] || "default"
            end_line = stripped.include?("{") ? find_closing_brace(i) : find_statement_end(i)
            body_for_calls = extract_lines(line_num, end_line)
            calls = extract_calls(body_for_calls, fn_name)

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
            i = end_line - 1 if end_line > line_num
          elsif (match = stripped.match(
                  /^(?:export\s+)?(?:const|let|var)\s+([A-Za-z0-9_$]+)(?:\s*:\s*[^=]+)?\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z0-9_$]+)\s*=>/
                )) ||
                (match = stripped.match(/^(?:export\s+)?(?:const|let|var)\s+([A-Za-z0-9_$]+)\s*=\s*(?:async\s*)?function\b/))
            fn_name = match[1]
            end_line = stripped.include?("{") ? find_closing_brace(i) : find_statement_end(i)
            body_for_calls = extract_lines(line_num, end_line)
            calls = extract_calls(body_for_calls, fn_name)

            symbols << Symbol.new(
              name: fn_name,
              kind: :function,
              file: @file_path,
              line_start: line_num,
              line_end: end_line,
              signature: line.split("=>").first.to_s.strip.sub(/=\s*$/, "").strip,
              calls: calls,
              body_loader: body_loader_for(line_num, end_line)
            )
            i = end_line - 1 if end_line > line_num
          elsif (match = stripped.match(/^(?:const|let|var)\s+([A-Za-z0-9_$]+)\s*=\s*require\((.*?)\)/))
            symbols << Symbol.new(
              name: stripped.sub(/;$/, ""),
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: stripped
            )
          elsif current_class && (match = stripped.match(
                /^(?:(?:public|private|protected|static|async|get|set)\s+)*([A-Za-z0-9_$]+)\s*\([^)]*\)(?:\s*:\s*[^{]+)?\s*\{/
              ))
            method_name = match[1]
            unless ["if", "for", "while", "switch", "catch", "function"].include?(method_name)
              full_name = "#{current_class}##{method_name}"
              end_line = find_closing_brace(i)
              body = extract_lines(line_num, end_line)
              calls = extract_calls(body, method_name)

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
              i = end_line - 1 if end_line > line_num
            end
          end

          i += 1
        end

        symbols
      end

      private

      def extract_calls(body, self_name)
        calls = body.scan(/\b([A-Za-z0-9_$]+)\s*\(/).flatten.uniq
        keywords = [
          "if", "else", "for", "while", "do", "switch", "case", "return", "catch", "function", "import",
          "require", "typeof", "instanceof", "throw", "new", "try", "finally", "delete", "void", "yield",
          "await", "super", "class", "interface", "type", "const", "let", "var"
        ]
        calls.reject { |c| c == self_name || keywords.include?(c) }
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

        @lines.size
      end

      def find_statement_end(start_idx)
        (start_idx..@lines.size - 1).each do |idx|
          return idx + 1 if @lines[idx].include?(";")
        end
        start_idx + 1
      end

      def find_import_end(start_idx)
        (start_idx..@lines.size - 1).each do |idx|
          line = @lines[idx]
          return idx + 1 if line.include?(";") || line.include?("from ") || line.include?("from'") || line.include?('from"')
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
