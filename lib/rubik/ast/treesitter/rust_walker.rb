# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class RustWalker < BaseWalker
        def walk(root_node)
          symbols = []
          return symbols unless root_node

          walk_children(root_node, symbols, nil)
          symbols
        end

        private

        def walk_children(node, symbols, impl_type, depth: 0)
          return if depth > 50

          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            case child.kind
            when "struct_item"
              walk_struct(child, symbols)
            when "enum_item"
              walk_enum(child, symbols)
            when "impl_item"
              walk_impl(child, symbols, depth: depth + 1)
            when "function_item"
              walk_function(child, symbols, impl_type)
            when "use_declaration"
              walk_use(child, symbols)
            else
              walk_children(child, symbols, impl_type, depth: depth + 1)
            end
          end
        end

        def walk_struct(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          name = text_for(name_node)
          sig = clean_signature(node)
          symbols << build_symbol(
            name: name,
            kind: :struct,
            node: node,
            signature: sig.empty? ? "struct #{name}" : sig
          )
        end

        def walk_enum(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          name = text_for(name_node)
          sig = clean_signature(node)
          symbols << build_symbol(
            name: name,
            kind: :enum,
            node: node,
            signature: sig.empty? ? "enum #{name}" : sig
          )
        end

        def walk_impl(node, symbols, depth: 0)
          type_node = node.child_by_field_name("type")
          impl_name = type_node ? text_for(type_node).strip : nil

          body = node.child_by_field_name("body")
          walk_children(body, symbols, impl_name, depth: depth + 1) if body
        end

        def walk_function(node, symbols, impl_type)
          name_node = node.child_by_field_name("name")
          return unless name_node

          fn_name = text_for(name_node)
          full_name = impl_type ? "#{impl_type}::#{fn_name}" : fn_name
          body = node.child_by_field_name("body")
          calls = extract_rust_calls(body)

          sig = clean_signature(node)
          symbols << build_symbol(
            name: full_name,
            kind: :function,
            node: node,
            signature: sig.empty? ? "fn #{fn_name}()" : sig,
            calls: calls
          )
        end

        def walk_use(node, symbols)
          raw = text_for(node).strip.sub(/;\z/, "")
          symbols << build_symbol(
            name: raw,
            kind: :import,
            node: node,
            signature: raw
          )
        end

        def extract_rust_calls(body_node)
          calls = []
          return calls unless body_node

          stack = [body_node]
          while (n = stack.pop)
            if n.kind == "call_expression"
              fn = n.child_by_field_name("function")
              if fn
                fn_text = text_for(fn).split("::").last&.strip
                calls << fn_text if fn_text && !fn_text.empty?
              end
            elsif n.kind == "macro_invocation"
              macro = n.child_by_field_name("macro") || n.named_child(0)
              if macro
                macro_text = text_for(macro).sub(/!\z/, "").split("::").last&.strip
                calls << macro_text if macro_text && !macro_text.empty?
              end
            end
            (0...n.named_child_count).reverse_each { |i| stack.push(n.named_child(i)) }
          end
          calls.uniq
        end
      end
    end
  end
end
