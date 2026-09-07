# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class ZigWalker < BaseWalker
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
            when "Decl"
              walk_decl(child, symbols)
            else
              walk_children(child, symbols)
            end
          end
        end

        def walk_decl(node, symbols)
          raw = text_for(node).strip

          if raw.include?("@import") && (raw.start_with?("const ") || raw.start_with?("pub const "))
            sig = raw.sub(/;\z/, "").strip
            symbols << build_symbol(
              name: sig,
              kind: :import,
              node: node,
              signature: sig
            )
          elsif (m = raw.match(/(?:pub\s+)?const\s+([A-Za-z0-9_]+)\s*=\s*(struct|enum)\b/))
            name = m[1]
            kind = m[2].to_sym
            sig = clean_signature(node)
            symbols << build_symbol(
              name: name,
              kind: kind,
              node: node,
              signature: sig.empty? ? "const #{name} = #{kind}" : sig
            )
          else
            # Check for function prototype inside Decl
            fn_proto = find_fn_proto(node)
            if fn_proto
              name_node = fn_proto.child_by_field_name("function")
              if name_node
                fn_name = text_for(name_node).strip
                calls = extract_calls(node, ["FieldOrFnCall", "call_expression"])
                sig = clean_signature(fn_proto)
                symbols << build_symbol(
                  name: fn_name,
                  kind: :function,
                  node: node,
                  signature: sig.empty? ? "fn #{fn_name}()" : sig,
                  calls: calls
                )
              end
            end
          end
        end

        def find_fn_proto(node)
          return node if node.kind == "FnProto"

          (0...node.named_child_count).each do |i|
            found = find_fn_proto(node.named_child(i))
            return found if found
          end
          nil
        end
      end
    end
  end
end
