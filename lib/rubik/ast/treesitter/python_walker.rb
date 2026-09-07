# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class PythonWalker < BaseWalker
        def walk(root_node)
          symbols = []
          return symbols unless root_node

          walk_children(root_node, symbols, nil)
          symbols
        end

        private

        def walk_children(node, symbols, current_class)
          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            case child.kind
            when "class_definition"
              walk_class(child, symbols)
            when "function_definition"
              walk_function(child, symbols, current_class)
            when "import_statement", "import_from_statement"
              walk_import(child, symbols)
            else
              walk_children(child, symbols, current_class)
            end
          end
        end

        def walk_class(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          class_name = text_for(name_node)
          sig = text_for(node).lines.first.to_s.strip.sub(/:$/, "")
          docstring = extract_docstring(node.child_by_field_name("body"))

          symbols << build_symbol(
            name: class_name,
            kind: :class,
            node: node,
            signature: sig,
            docstring: docstring
          )

          body = node.child_by_field_name("body")
          walk_children(body, symbols, class_name) if body
        end

        def walk_function(node, symbols, current_class)
          name_node = node.child_by_field_name("name")
          return unless name_node

          fn_name = text_for(name_node)
          full_name = current_class ? "#{current_class}.#{fn_name}" : fn_name
          params = node.child_by_field_name("parameters")
          sig = "def #{fn_name}#{text_for(params)}"
          body = node.child_by_field_name("body")
          calls = extract_calls(body, ["call"])
          docstring = extract_docstring(body)

          symbols << build_symbol(
            name: full_name,
            kind: :function,
            node: node,
            signature: sig,
            calls: calls,
            docstring: docstring
          )
        end

        def walk_import(node, symbols)
          text = text_for(node).strip
          symbols << build_symbol(
            name: text,
            kind: :import,
            node: node,
            signature: text
          )
        end

        def extract_docstring(body_node)
          return nil unless body_node&.named_child_count&.positive?

          first_stmt = body_node.named_child(0)
          return nil unless first_stmt

          str_node = if first_stmt.kind == "string"
                       first_stmt
                     elsif first_stmt.kind == "expression_statement" && first_stmt.named_child(0)&.kind == "string"
                       first_stmt.named_child(0)
                     end
          return nil unless str_node

          text_for(str_node).gsub(/^["']{3}|["']{3}$/, "").strip
        end
      end
    end
  end
end
