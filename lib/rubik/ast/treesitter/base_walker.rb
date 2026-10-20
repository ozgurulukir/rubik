# frozen_string_literal: true

require_relative "../symbol"
require_relative "../body_loader"

module Rubik
  module AST
    module TreeSitter
      class BaseWalker
        include BodyLoader

        attr_reader :file_path, :code

        def initialize(file_path, code)
          @file_path = file_path
          @code = code || ""
          @lines = nil
        end

        def lines
          @lines ||= @code.lines
        end

        def extract_lines(start_line, end_line)
          return "" if lines.empty?

          s_idx = [start_line - 1, 0].max
          e_idx = [end_line - 1, lines.size - 1].min
          lines[s_idx..e_idx]&.join || ""
        end

        def text_for(node)
          return "" unless node

          @code.byteslice(node.start_byte...node.end_byte) || ""
        end

        def clean_signature(node, max_length: 300)
          return "" unless node

          first_line = text_for(node).lines.first.to_s.strip
          clean = first_line.sub(/\{$/, "").strip
          clean.length > max_length ? "#{clean[0...max_length]}..." : clean
        end

        def line_start(node)
          node ? node.start_position.row + 1 : 1
        end

        def line_end(node)
          node ? node.end_position.row + 1 : 1
        end

        def build_symbol(name:, kind:, node:, signature: nil, calls: [], docstring: nil)
          l_start = line_start(node)
          l_end = line_end(node)
          sig = (signature || name).to_s
          sig = "#{sig[0...300]}..." if sig.length > 300
          Symbol.new(
            name: name,
            kind: kind,
            file: @file_path,
            line_start: l_start,
            line_end: l_end,
            signature: sig,
            calls: calls,
            body_loader: body_loader_for(l_start, l_end),
            docstring: docstring
          )
        end

        # Traverses an AST subtree iteratively to extract called function/method identifiers
        def extract_calls(node, call_kinds = ["call", "call_expression", "invocation"])
          calls = []
          return calls unless node

          stack = [node]
          while (n = stack.pop)
            if call_kinds.include?(n.kind)
              fn = n.child_by_field_name("function") || n.child_by_field_name("name") || n.named_child(0)
              if fn
                # Keep receiver and namespace text. Stripping this to a bare
                # method name made dynamic dispatch look like a call to every
                # same-named definition in the graph.
                fn_name = text_for(fn).strip
                calls << fn_name if fn_name && !fn_name.empty?
              end
            end
            (0...n.named_child_count).reverse_each { |i| stack.push(n.named_child(i)) }
          end
          calls.uniq
        end

        # Helper to extract leading comment or docstring
        def docstring_before(node)
          parent = node&.parent
          return nil unless parent

          idx = (0...parent.named_child_count).find { |i| parent.named_child(i) == node }
          return nil unless idx&.positive?

          prev = parent.named_child(idx - 1)
          return nil unless prev&.kind&.include?("comment")

          text_for(prev).strip
        end
      end
    end
  end
end
