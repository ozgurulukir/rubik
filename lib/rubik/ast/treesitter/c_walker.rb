# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class CWalker < BaseWalker
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
            when "preproc_include"
              walk_include(child, symbols)
            when "type_definition"
              walk_typedef(child, symbols)
            when "struct_specifier"
              walk_struct(child, symbols)
            when "function_definition"
              walk_function(child, symbols)
            else
              walk_children(child, symbols)
            end
          end
        end

        def walk_include(node, symbols)
          raw = text_for(node).strip
          symbols << build_symbol(
            name: raw,
            kind: :import,
            node: node,
            signature: raw
          )
        end

        def walk_typedef(node, symbols)
          declarator = node.child_by_field_name("declarator")
          name = if declarator
                   text_for(declarator).strip
                 else
                   type_node = node.child_by_field_name("type")
                   text_for(type_node&.child_by_field_name("name")).strip
                 end
          return if name.empty?

          sig = clean_signature(node)
          symbols << build_symbol(
            name: name,
            kind: :struct,
            node: node,
            signature: sig.empty? ? "typedef struct #{name}" : sig
          )
        end

        def walk_struct(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          name = text_for(name_node).strip
          return if name.empty?

          sig = "struct #{name}"
          symbols << build_symbol(
            name: name,
            kind: :struct,
            node: node,
            signature: sig
          )
        end

        def walk_function(node, symbols)
          decl = node.child_by_field_name("declarator")
          return unless decl

          fn_name = extract_function_name(decl)
          return if fn_name.nil? || fn_name.empty?

          body = node.child_by_field_name("body")
          calls = extract_calls(body, ["call_expression"])

          sig = clean_signature(node)
          symbols << build_symbol(
            name: fn_name,
            kind: :function,
            node: node,
            signature: sig.empty? ? "#{fn_name}()" : sig,
            calls: calls
          )
        end

        def extract_function_name(declarator_node)
          current = declarator_node
          while current
            case current.kind
            when "function_declarator", "pointer_declarator"
              current = current.child_by_field_name("declarator")
            when "identifier"
              return text_for(current).strip
            else
              # Try first identifier child
              ident = current.children.find { |c| c.kind == "identifier" }
              return text_for(ident).strip if ident

              return text_for(current).strip
            end
          end
        end
      end
    end
  end
end
