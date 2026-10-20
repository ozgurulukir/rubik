# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class ZigWalker < BaseWalker
        FN_KINDS = ["FnProto", "ProtoDecl", "FunctionDecl", "function_definition"].freeze
        private_constant :FN_KINDS

        def walk(root_node)
          symbols = []
          return symbols unless root_node

          walk_children(root_node, symbols)
          symbols
        end

        private

        def walk_children(node, symbols, depth: 0)
          return if depth > 50

          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            case child.kind
            when "Decl"
              walk_decl(child, symbols)
            else
              walk_children(child, symbols, depth: depth + 1)
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
            # Check for a function definition inside this Decl. The function
            # name lives on the `identifier` child of a function_definition
            # node — the old `child_by_field_name("function")` lookup only
            # exists on call expressions and is nil on a function decl, which
            # silently dropped every Zig function from the symbol graph.
            fn_def = find_function(node)
            if fn_def
              name_node = fn_def.child_by_field_name("function") ||
                          fn_def.child_by_field_name("name") ||
                          find_identifier(fn_def)
              if name_node
                fn_name = text_for(name_node).strip
                calls = extract_calls(node, ["FieldOrFnCall", "call_expression"])
                sig = clean_signature(fn_def)
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

        # Locates the node that owns this Decl's function definition. Zig
        # exposes it under several kind names across grammar versions, so we
        # accept every one we know about rather than only "FnProto".
        def find_function(node, depth: 0)
          return if depth > 50
          return node if FN_KINDS.include?(node.kind)

          (0...node.named_child_count).each do |i|
            found = find_function(node.named_child(i), depth: depth + 1)
            return found if found
          end
          nil
        end

        # Walks the subtree for the first identifier node — used as a fallback
        # when the grammar does not expose the function name as a named field.
        def find_identifier(node, depth: 0)
          return if depth > 50
          return node if node.kind == "identifier"

          (0...node.named_child_count).each do |i|
            found = find_identifier(node.named_child(i), depth: depth + 1)
            return found if found
          end
          nil
        end
      end
    end
  end
end
