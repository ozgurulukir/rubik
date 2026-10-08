# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rubik/ast/treesitter/base_walker"
require_relative "../../lib/rubik/ast/treesitter/typescript_walker"

class TestTypeScriptWalker < Minitest::Test
  class MockNode
    attr_accessor :kind, :named_children, :fields, :start_byte, :end_byte, :start_row, :end_row

    def initialize(kind:, named_children: [], fields: {}, start_byte: 0, end_byte: 0, start_row: 0, end_row: 0)
      @kind = kind
      @named_children = named_children
      @fields = fields
      @start_byte = start_byte
      @end_byte = end_byte
      @start_row = start_row
      @end_row = end_row
    end

    def named_child_count
      @named_children.size
    end

    def named_child(i)
      @named_children[i]
    end

    def child_by_field_name(name)
      @fields[name]
    end

    def start_position
      Struct.new(:row, :column).new(@start_row, 0)
    end

    def end_position
      Struct.new(:row, :column).new(@end_row, 0)
    end
  end

  def test_walk_returns_empty_when_root_node_is_nil
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("test.ts", "")
    assert_equal [], walker.walk(nil)
  end

  def test_walk_import_statement
    code = "import { useState } from 'react';"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("test.ts", code)

    import_node = MockNode.new(kind: "import_statement", start_byte: 0, end_byte: code.length, start_row: 0, end_row: 0)
    root = MockNode.new(kind: "program", named_children: [import_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    sym = symbols.first
    assert_equal "import { useState } from 'react'", sym.name
    assert_equal :import, sym.kind
    assert_equal "import { useState } from 'react'", sym.signature
  end

  def test_walk_interface_declaration
    code = "interface User {\n  id: number;\n}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("user.ts", code)

    name_node = MockNode.new(kind: "identifier", start_byte: 10, end_byte: 14, start_row: 0, end_row: 0)
    interface_node = MockNode.new(
      kind: "interface_declaration",
      fields: { "name" => name_node },
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 2
    )
    root = MockNode.new(kind: "program", named_children: [interface_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    sym = symbols.first
    assert_equal "User", sym.name
    assert_equal :interface, sym.kind
    assert_equal "interface User", sym.signature
  end

  def test_walk_interface_declaration_without_name
    code = "interface {\n  id: number;\n}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("user.ts", code)

    interface_node = MockNode.new(
      kind: "interface_declaration",
      fields: {},
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 2
    )
    root = MockNode.new(kind: "program", named_children: [interface_node])

    symbols = walker.walk(root)
    assert_empty symbols
  end

  def test_walk_enum_declaration
    code = "enum Status {\n  Active,\n  Inactive\n}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("status.ts", code)

    name_node = MockNode.new(kind: "identifier", start_byte: 5, end_byte: 11, start_row: 0, end_row: 0)
    enum_node = MockNode.new(
      kind: "enum_declaration",
      fields: { "name" => name_node },
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 3
    )
    root = MockNode.new(kind: "program", named_children: [enum_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    sym = symbols.first
    assert_equal "Status", sym.name
    assert_equal :enum, sym.kind
    assert_equal "enum Status", sym.signature
  end

  def test_walk_enum_declaration_without_name
    code = "enum {\n  Active\n}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("status.ts", code)

    enum_node = MockNode.new(
      kind: "enum_declaration",
      fields: {},
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 2
    )
    root = MockNode.new(kind: "program", named_children: [enum_node])

    symbols = walker.walk(root)
    assert_empty symbols
  end

  def test_walk_class_declaration_and_body_methods
    code = <<~TS
      class UserService {
        getUser() {
          return fetchUser();
        }
      }
    TS
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("service.ts", code)

    class_name_node = MockNode.new(kind: "identifier", start_byte: 6, end_byte: 17, start_row: 0, end_row: 0)

    method_name_node = MockNode.new(kind: "property_identifier", start_byte: 22, end_byte: 29, start_row: 1, end_row: 1)
    call_fn_node = MockNode.new(kind: "identifier", start_byte: 45, end_byte: 54, start_row: 2, end_row: 2)
    call_expr_node = MockNode.new(
      kind: "call_expression",
      fields: { "function" => call_fn_node },
      start_byte: 45,
      end_byte: 56,
      start_row: 2,
      end_row: 2
    )
    method_body_node = MockNode.new(kind: "statement_block", named_children: [call_expr_node], start_byte: 34, end_byte: 62, start_row: 1, end_row: 3)
    method_node = MockNode.new(
      kind: "method_definition",
      fields: { "name" => method_name_node, "body" => method_body_node },
      start_byte: 22,
      end_byte: 62,
      start_row: 1,
      end_row: 3
    )

    class_body_node = MockNode.new(kind: "class_body", named_children: [method_node], start_byte: 18, end_byte: 65, start_row: 0, end_row: 4)
    class_node = MockNode.new(
      kind: "class_declaration",
      fields: { "name" => class_name_node, "body" => class_body_node },
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 4
    )

    root = MockNode.new(kind: "program", named_children: [class_node])

    symbols = walker.walk(root)
    assert_equal 2, symbols.size

    class_sym = symbols.find { |s| s.name == "UserService" }
    assert class_sym
    assert_equal :class, class_sym.kind

    method_sym = symbols.find { |s| s.name == "UserService#getUser" }
    assert method_sym
    assert_equal :function, method_sym.kind
    assert_equal ["fetchUser"], method_sym.calls
  end

  def test_walk_class_declaration_without_name
    code = "class {\n}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("anon.ts", code)

    class_node = MockNode.new(
      kind: "class_declaration",
      fields: {},
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 1
    )
    root = MockNode.new(kind: "program", named_children: [class_node])

    symbols = walker.walk(root)
    assert_empty symbols
  end

  def test_walk_function_declaration
    code = "function calculateTotal() {\n  log();\n}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("calc.ts", code)

    fn_name_node = MockNode.new(kind: "identifier", start_byte: 9, end_byte: 23, start_row: 0, end_row: 0)
    call_fn_node = MockNode.new(kind: "identifier", start_byte: 30, end_byte: 33, start_row: 1, end_row: 1)
    call_expr_node = MockNode.new(
      kind: "call_expression",
      fields: { "function" => call_fn_node },
      start_byte: 30,
      end_byte: 35,
      start_row: 1,
      end_row: 1
    )
    fn_body_node = MockNode.new(kind: "statement_block", named_children: [call_expr_node], start_byte: 26, end_byte: 39, start_row: 0, end_row: 2)

    fn_node = MockNode.new(
      kind: "function_declaration",
      fields: { "name" => fn_name_node, "body" => fn_body_node },
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 2
    )

    root = MockNode.new(kind: "program", named_children: [fn_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    sym = symbols.first
    assert_equal "calculateTotal", sym.name
    assert_equal :function, sym.kind
    assert_equal ["log"], sym.calls
  end

  def test_walk_function_declaration_without_name
    code = "function() {}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("calc.ts", code)

    fn_node = MockNode.new(
      kind: "function_declaration",
      fields: {},
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 0
    )

    root = MockNode.new(kind: "program", named_children: [fn_node])

    symbols = walker.walk(root)
    assert_empty symbols
  end

  def test_walk_variable_declarations_with_arrow_or_function_expression
    code = "const handleClick = () => { trigger(); };"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("var.ts", code)

    var_name_node = MockNode.new(kind: "identifier", start_byte: 6, end_byte: 17, start_row: 0, end_row: 0)

    call_fn_node = MockNode.new(kind: "identifier", start_byte: 28, end_byte: 35, start_row: 0, end_row: 0)
    call_expr_node = MockNode.new(
      kind: "call_expression",
      fields: { "function" => call_fn_node },
      start_byte: 28,
      end_byte: 37,
      start_row: 0,
      end_row: 0
    )
    arrow_body_node = MockNode.new(kind: "statement_block", named_children: [call_expr_node], start_byte: 26, end_byte: 39, start_row: 0, end_row: 0)
    arrow_fn_node = MockNode.new(kind: "arrow_function", fields: { "body" => arrow_body_node }, start_byte: 20, end_byte: 39, start_row: 0, end_row: 0)

    declarator_node = MockNode.new(
      kind: "variable_declarator",
      fields: { "name" => var_name_node, "value" => arrow_fn_node },
      start_byte: 6,
      end_byte: 39,
      start_row: 0,
      end_row: 0
    )

    lexical_node = MockNode.new(
      kind: "lexical_declaration",
      named_children: [declarator_node],
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 0
    )

    root = MockNode.new(kind: "program", named_children: [lexical_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    sym = symbols.first
    assert_equal "handleClick", sym.name
    assert_equal :function, sym.kind
    assert_equal ["trigger"], sym.calls
  end

  def test_walk_export_statement_wrapping_declarations
    code = "export interface Config { debug: boolean; }"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("config.ts", code)

    name_node = MockNode.new(kind: "identifier", start_byte: 17, end_byte: 23, start_row: 0, end_row: 0)
    interface_node = MockNode.new(
      kind: "interface_declaration",
      fields: { "name" => name_node },
      start_byte: 7,
      end_byte: code.length,
      start_row: 0,
      end_row: 0
    )

    export_node = MockNode.new(
      kind: "export_statement",
      named_children: [interface_node],
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 0
    )

    root = MockNode.new(kind: "program", named_children: [export_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    sym = symbols.first
    assert_equal "Config", sym.name
    assert_equal :interface, sym.kind
  end

  def test_walk_unhandled_parent_node_recurses_children
    code = "function inner() {}"
    walker = Rubik::AST::TreeSitter::TypeScriptWalker.new("unhandled.ts", code)

    fn_name_node = MockNode.new(kind: "identifier", start_byte: 9, end_byte: 14, start_row: 0, end_row: 0)
    fn_node = MockNode.new(
      kind: "function_declaration",
      fields: { "name" => fn_name_node },
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 0
    )

    wrapper_node = MockNode.new(
      kind: "some_unhandled_wrapper",
      named_children: [fn_node],
      start_byte: 0,
      end_byte: code.length,
      start_row: 0,
      end_row: 0
    )

    root = MockNode.new(kind: "program", named_children: [wrapper_node])

    symbols = walker.walk(root)
    assert_equal 1, symbols.size
    assert_equal "inner", symbols.first.name
  end
end
