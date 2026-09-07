# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class GoWalker < BaseWalker
        def walk(root_node)
          symbols = []
          return symbols unless root_node

          walk_children(root_node, symbols)
          symbols
        end

        private

        def walk_children(node, symbols)
          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            case child.kind
            when "type_declaration"
              walk_type_declaration(child, symbols)
            when "type_spec"
              walk_type_spec(child, symbols)
            when "method_declaration"
              walk_method(child, symbols)
            when "function_declaration"
              walk_function(child, symbols)
            when "import_declaration"
              walk_import(child, symbols)
            else
              walk_children(child, symbols)
            end
          end
        end

        def walk_type_declaration(node, symbols)
          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            walk_type_spec(child, symbols) if child.kind == "type_spec"
          end
        end

        def walk_type_spec(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          name = text_for(name_node)
          type_node = node.child_by_field_name("type")
          kind = case type_node&.kind
                 when "struct_type" then :struct
                 when "interface_type" then :interface
                 else :type
                 end

          sig = "type #{name} #{kind}"
          symbols << build_symbol(
            name: name,
            kind: kind,
            node: node,
            signature: sig
          )
        end

        def walk_method(node, symbols)
          name_node = node.child_by_field_name("name")
          recv_node = node.child_by_field_name("receiver")
          return unless name_node && recv_node

          method_name = text_for(name_node)
          recv_text = text_for(recv_node).strip
          full_name = "#{recv_text}.#{method_name}"

          body = node.child_by_field_name("body")
          calls = extract_calls(body, ["call_expression"])

          sig_line = clean_signature(node)
          symbols << build_symbol(
            name: full_name,
            kind: :function,
            node: node,
            signature: sig_line.empty? ? full_name : sig_line,
            calls: calls
          )
        end

        def walk_function(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          fn_name = text_for(name_node)
          body = node.child_by_field_name("body")
          calls = extract_calls(body, ["call_expression"])

          sig_line = clean_signature(node)
          symbols << build_symbol(
            name: fn_name,
            kind: :function,
            node: node,
            signature: sig_line.empty? ? "func #{fn_name}()" : sig_line,
            calls: calls
          )
        end

        def walk_import(node, symbols)
          raw = text_for(node).strip
          name = raw.include?("(") ? "import (...)" : raw.lines.first.to_s.strip
          symbols << build_symbol(
            name: name,
            kind: :import,
            node: node,
            signature: name
          )
        end
      end
    end
  end
end
