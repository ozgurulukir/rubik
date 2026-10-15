# frozen_string_literal: true

require_relative "base_walker"

module Rubik
  module AST
    module TreeSitter
      # Shared C/C++ walker (issue #147). Supported scope, pinned by
      # test_ast_cpp_extraction.rb:
      #   • includes, typedefs, and struct/union/class specifiers (nested
      #     classes qualify as Outer::Inner);
      #   • free functions and in-class member definitions/declarations,
      #     including constructors, destructors, and operator overloads;
      #   • namespaces: symbol names carry the namespace path (app::run);
      #   • templates: a template_declaration is unwrapped and its inner
      #     class/function is walked (specialization nuances are out of scope).
      # Qualification follows the project convention: namespace/enclosing
      # segments join with "::", an in-class member joins its class with "#"
      # (app::Widget#run — the same Class#method shape the TypeScript and
      # Python walkers use). Out-of-line definitions keep their written
      # spelling (`void Widget::run` stays "Widget::run").
      # Out of scope (documented boundary): macro bodies, free-function
      # prototypes outside a class, local classes inside function bodies, and
      # declarators hidden behind attributes/`decltype` syntax.
      class CWalker < BaseWalker
        RECORD_KINDS = {
          "class_specifier" => :class,
          "struct_specifier" => :struct,
          "union_specifier" => :union
        }.freeze

        DECLARATOR_WRAPPERS = [
          "function_declarator", "pointer_declarator", "reference_declarator", "parenthesized_declarator"
        ].freeze
        NAME_NODE_KINDS = [
          "identifier", "field_identifier", "type_identifier", "destructor_name", "operator_name"
        ].freeze

        def walk(root_node)
          symbols = []
          return symbols unless root_node

          walk_children(root_node, symbols, [], member: false)
          symbols
        end

        private

        # `scope` is the enclosing declaration path (namespaces, then the
        # innermost class, outermost first); `member` marks a class body so
        # declarations are read as member declarations.
        def walk_children(node, symbols, scope, member:)
          (0...node.named_child_count).each do |i|
            child = node.named_child(i)
            case child.kind
            when "preproc_include"
              walk_include(child, symbols)
            when "type_definition"
              walk_typedef(child, symbols, scope)
            when *RECORD_KINDS.keys
              walk_record(child, symbols, scope)
            when "namespace_definition"
              walk_namespace(child, symbols, scope)
            when "function_definition"
              walk_function(child, symbols, scope, member: member)
            when "field_declaration", "declaration"
              walk_member_declaration(child, symbols, scope) if member
            else
              # Plain recursion also unwraps template_declaration nodes (their
              # inner class/function is walked in place) and linkage
              # specifications.
              walk_children(child, symbols, scope, member: member)
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

        def walk_typedef(node, symbols, scope)
          declarator = node.child_by_field_name("declarator")
          name = if declarator
                   text_for(declarator).strip
                 else
                   type_node = node.child_by_field_name("type")
                   text_for(type_node&.child_by_field_name("name")).strip
                 end
          return if name.empty?

          qualified = qualify(scope, name)
          sig = clean_signature(node)
          symbols << build_symbol(
            name: qualified,
            kind: :struct,
            node: node,
            signature: sig.empty? ? "typedef struct #{qualified}" : sig
          )
        end

        def walk_record(node, symbols, scope)
          name_node = node.child_by_field_name("name")
          return unless name_node

          name = text_for(name_node).strip
          return if name.empty?

          kind = RECORD_KINDS.fetch(node.kind, :struct)
          qualified = qualify(scope, name)
          sig = clean_signature(node)
          symbols << build_symbol(
            name: qualified,
            kind: kind,
            node: node,
            signature: sig.empty? ? "#{kind} #{qualified}" : sig
          )

          body = node.child_by_field_name("body")
          walk_children(body, symbols, scope + [name], member: true) if body
        end

        # Namespace names extend the qualification path; everything inside is
        # walked with the namespace prefix (app::run, app::Widget#run).
        def walk_namespace(node, symbols, scope)
          name_node = node.child_by_field_name("name")
          ns_scope = name_node ? scope + [text_for(name_node).strip] : scope
          body = node.child_by_field_name("body")
          walk_children(body, symbols, ns_scope, member: false) if body
        end

        def walk_function(node, symbols, scope, member:)
          decl = node.child_by_field_name("declarator")
          return unless decl

          fn_name = extract_function_name(decl)
          return if fn_name.nil? || fn_name.empty?

          body = node.child_by_field_name("body")
          calls = extract_calls(body, ["call_expression"])
          qualified = member ? member_name(scope, fn_name) : qualify(scope, fn_name)

          sig = clean_signature(node)
          symbols << build_symbol(
            name: qualified,
            kind: :function,
            node: node,
            signature: sig.empty? ? "#{fn_name}()" : sig,
            calls: calls
          )
        end

        # In-class member DECLARATIONS without a body: `void run();`, `C();`,
        # `~C();`, `void operator+(int);`, `operator bool() const;`. Plain
        # field declarations (`int x;`) are not symbols.
        def walk_member_declaration(node, symbols, scope)
          return if scope.empty?

          decl = node.child_by_field_name("declarator")
          return unless decl

          name = if decl.kind == "operator_cast"
                   type_node = decl.child_by_field_name("type")
                   type_node ? "operator #{text_for(type_node).strip}" : nil
                 elsif callable_declarator?(decl)
                   extract_function_name(decl)
                 end
          return if name.nil? || name.empty?

          sig = clean_signature(node)
          symbols << build_symbol(
            name: member_name(scope, name),
            kind: :function,
            node: node,
            signature: sig.empty? ? "#{name}()" : sig
          )
        end

        def callable_declarator?(decl)
          current = decl
          while current
            return true if current.kind == "function_declarator"

            break unless DECLARATOR_WRAPPERS.include?(current.kind)

            current = current.child_by_field_name("declarator")
          end
          false
        end

        # Resolves a callable's name from its declarator chain: identifiers
        # (C and free functions), field_identifier (in-class methods),
        # destructor_name (~C), operator_name (operator+), and
        # qualified_identifier (out-of-line Widget::run). Only known
        # declarator wrappers are descended; anything else ends the walk with
        # nil — a wrong name is worse than a missing symbol.
        def extract_function_name(declarator_node)
          current = declarator_node
          while current
            kind = current.kind
            return text_for(current).strip if NAME_NODE_KINDS.include?(kind) || kind == "qualified_identifier"

            return nil unless DECLARATOR_WRAPPERS.include?(kind)

            current = current.child_by_field_name("declarator")
          end
          nil
        end

        # Namespace/enclosing-class segments join with "::"; an in-class
        # member joins its class with "#" (see the class comment).
        def qualify(scope, name)
          scope.empty? ? name : "#{scope.join('::')}::#{name}"
        end

        def member_name(scope, name)
          return name if scope.empty?

          *outer, klass = scope
          (outer + ["#{klass}##{name}"]).join("::")
        end
      end
    end
  end
end
