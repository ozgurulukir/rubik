# frozen_string_literal: true

require_relative "symbol"

module Rubik
  module AST
    class RubyExtractor
      begin
        require "prism"
        PRISM_AVAILABLE = true
      rescue LoadError
        PRISM_AVAILABLE = false
      end

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

        if PRISM_AVAILABLE
          extract_via_prism(symbols)
        else
          extract_via_fallback(symbols)
        end
        symbols
      end

      private

      def extract_via_prism(symbols)
        result = Prism.parse(@content)
        return unless result.value

        walk_node(result.value, nil, symbols)
      end

      def walk_node(node, current_scope, symbols)
        return unless node

        case node
        when Prism::ClassNode
          name = node.name.to_s
          line_start = node.location.start_line
          line_end = node.location.end_line
          symbols << Symbol.new(
            name: name,
            kind: :class,
            file: @file_path,
            line_start: line_start,
            line_end: line_end,
            signature: "class #{name}"
          )
          node.compact_child_nodes.each { |child| walk_node(child, name, symbols) }

        when Prism::ModuleNode
          name = node.name.to_s
          line_start = node.location.start_line
          line_end = node.location.end_line
          symbols << Symbol.new(
            name: name,
            kind: :module,
            file: @file_path,
            line_start: line_start,
            line_end: line_end,
            signature: "module #{name}"
          )
          node.compact_child_nodes.each { |child| walk_node(child, name, symbols) }

        when Prism::DefNode
          method_name = node.name.to_s
          full_name = current_scope ? "#{current_scope}##{method_name}" : method_name
          line_start = node.location.start_line
          line_end = node.location.end_line
          body = extract_lines(line_start, line_end)
          calls = extract_calls_from_node(node, method_name)

          symbols << Symbol.new(
            name: full_name,
            kind: :function,
            file: @file_path,
            line_start: line_start,
            line_end: line_end,
            signature: "def #{method_name}",
            calls: calls,
            body: body
          )

        when Prism::CallNode
          name = node.name.to_s
          if %w[require require_relative].include?(name)
            line_num = node.location.start_line
            arg = node.arguments&.arguments&.first&.slice.to_s
            symbols << Symbol.new(
              name: "#{name} #{arg}",
              kind: :import,
              file: @file_path,
              line_start: line_num,
              line_end: line_num,
              signature: "#{name} #{arg}"
            )
          end
          node.compact_child_nodes.each { |child| walk_node(child, current_scope, symbols) }

        when Prism::ProgramNode, Prism::StatementsNode
          node.compact_child_nodes.each { |child| walk_node(child, current_scope, symbols) }
        else
          node.compact_child_nodes.each { |child| walk_node(child, current_scope, symbols) } if node.respond_to?(:compact_child_nodes)
        end
      end

      def extract_calls_from_node(node, self_name)
        calls = []
        queue = [node]

        while (curr = queue.pop)
          if curr.is_a?(Prism::CallNode)
            cname = curr.name.to_s
            calls << cname unless cname == self_name || %w[require require_relative raise puts p print].include?(cname)
          end
          queue.concat(curr.compact_child_nodes) if curr.respond_to?(:compact_child_nodes)
        end

        calls.uniq
      end

      def extract_via_fallback(symbols)
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
            body = extract_lines(line_num, end_line)
            calls = body.scan(/\b([a-z_][a-zA-Z0-9_]*)\s*\(/).flatten.uniq
            calls.reject! { |c| c == method_name || %w[def if unless case return raise puts p print require].include?(c) }

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
      end

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

      def extract_lines(start_line, end_line)
        s_idx = [start_line - 1, 0].max
        e_idx = [end_line - 1, @lines.size - 1].min
        @lines[s_idx..e_idx].join
      end
    end
  end
end
