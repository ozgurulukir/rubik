# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      class TypeScriptWalker < BaseWalker
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
            when "export_statement"
              walk_export(child, symbols, current_class)
            when "interface_declaration"
              walk_interface(child, symbols)
            when "enum_declaration"
              walk_enum(child, symbols)
            when "class_declaration"
              walk_class(child, symbols)
            when "function_declaration"
              walk_function(child, symbols)
            when "lexical_declaration", "variable_declaration"
              walk_variable_declaration(child, symbols)
            when "import_statement"
              walk_import(child, symbols)
            else
              walk_children(child, symbols, current_class)
            end
          end
        end

        def walk_export(node, symbols, current_class)
          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            case child.kind
            when "interface_declaration" then walk_interface(child, symbols)
            when "enum_declaration" then walk_enum(child, symbols)
            when "class_declaration" then walk_class(child, symbols)
            when "function_declaration" then walk_function(child, symbols)
            when "lexical_declaration", "variable_declaration" then walk_variable_declaration(child, symbols)
            else walk_children(child, symbols, current_class)
            end
          end
        end

        def walk_interface(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          name = text_for(name_node)
          sig = clean_signature(node)
          symbols << build_symbol(
            name: name,
            kind: :interface,
            node: node,
            signature: sig.empty? ? "interface #{name}" : sig
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

        def walk_class(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          class_name = text_for(name_node)
          sig = clean_signature(node)
          symbols << build_symbol(
            name: class_name,
            kind: :class,
            node: node,
            signature: sig.empty? ? "class #{class_name}" : sig
          )

          body = node.child_by_field_name("body")
          walk_class_body(body, symbols, class_name) if body
        end

        def walk_class_body(body_node, symbols, class_name)
          (0...body_node.named_child_count).each do |i|
            child = body_node.named_child(i)
            next unless child.kind == "method_definition"

            name_node = child.child_by_field_name("name")
            next unless name_node

            method_name = text_for(name_node)
            full_name = "#{class_name}##{method_name}"
            body = child.child_by_field_name("body")
            calls = extract_calls(body, ["call_expression"])

            sig = clean_signature(child)
            symbols << build_symbol(
              name: full_name,
              kind: :function,
              node: child,
              signature: sig.empty? ? "#{class_name}.#{method_name}()" : sig,
              calls: calls
            )
          end
        end

        def walk_function(node, symbols)
          name_node = node.child_by_field_name("name")
          return unless name_node

          fn_name = text_for(name_node)
          body = node.child_by_field_name("body")
          calls = extract_calls(body, ["call_expression"])

          sig = clean_signature(node)
          symbols << build_symbol(
            name: fn_name,
            kind: :function,
            node: node,
            signature: sig.empty? ? "function #{fn_name}()" : sig,
            calls: calls
          )
        end

        def walk_variable_declaration(node, symbols)
          (0...node.named_child_count).each do |i|
            decl = node.named_child(i)
            next unless decl.kind == "variable_declarator"

            val = decl.child_by_field_name("value")
            next unless val && ["arrow_function", "function_expression"].include?(val.kind)

            name_node = decl.child_by_field_name("name")
            next unless name_node

            fn_name = text_for(name_node)
            body = val.child_by_field_name("body")
            calls = extract_calls(body, ["call_expression"])

            sig = clean_signature(node)
            symbols << build_symbol(
              name: fn_name,
              kind: :function,
              node: node,
              signature: sig.empty? ? "const #{fn_name} = () =>" : sig,
              calls: calls
            )
          end
        end

        def walk_import(node, symbols)
          raw = text_for(node).strip.sub(/;\z/, "")
          symbols << build_symbol(
            name: raw,
            kind: :import,
            node: node,
            signature: raw
          )
        end
      end
    end
  end
end
