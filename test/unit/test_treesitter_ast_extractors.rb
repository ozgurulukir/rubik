# frozen_string_literal: true

require_relative "../test_helper"

class TestTreeSitterASTExtractors < Minitest::Test
  def setup
    @graph = Rubik::AST::Graph.new
  end

  def test_tree_sitter_availability
    assert Rubik::AST::TreeSitterExtractor.available?, "TreeSitterExtractor must be available via tree_sitter_language_pack"
    assert Rubik::AST::TreeSitterExtractor.supports?(".py")
    assert Rubik::AST::TreeSitterExtractor.supports?(".go")
    assert Rubik::AST::TreeSitterExtractor.supports?(".rs")
    assert Rubik::AST::TreeSitterExtractor.supports?(".ts")
    assert Rubik::AST::TreeSitterExtractor.supports?(".tsx")
    assert Rubik::AST::TreeSitterExtractor.supports?(".c")
    assert Rubik::AST::TreeSitterExtractor.supports?(".zig")
  end

  def test_go_brackets_in_strings_resilience
    code = <<~GO
      package main
      func FormatPayload() string {
          s := "{ corrupted: true, nested: { value: 1 } }"
          return s
      }
      func NextFunction() {}
    GO

    symbols = Rubik::AST::Extractor.extract("main.go", code)
    names = symbols.map(&:name)
    assert_includes names, "FormatPayload"
    assert_includes names, "NextFunction"

    format_sym = symbols.find { |s| s.name == "FormatPayload" }
    next_sym = symbols.find { |s| s.name == "NextFunction" }

    assert_equal 2, format_sym.line_start
    assert_equal 5, format_sym.line_end
    assert_equal 6, next_sym.line_start
  end

  def test_rust_macros_and_calls_accuracy
    code = <<~RS
      pub struct Engine;

      impl Engine {
          pub fn run(&self) {
              // This comment mentions if (false) and fake_call()
              let text = "string with (parentheses) and {braces}";
              println!("Running engine");
              validate_state();
          }
      }
    RS

    symbols = Rubik::AST::Extractor.extract("engine.rs", code)
    names = symbols.map(&:name)
    assert_includes names, "Engine"
    assert_includes names, "Engine::run"

    run_sym = symbols.find { |s| s.name == "Engine::run" }
    assert_equal :function, run_sym.kind
    assert_includes run_sym.calls, "println"
    assert_includes run_sym.calls, "validate_state"
    # False positives from comments or strings must NOT be present
    refute_includes run_sym.calls, "fake_call"
    refute_includes run_sym.calls, "if"
  end

  def test_typescript_tsx_and_arrow_functions
    tsx_code = <<~TSX
      import React, { useState } from "react";

      export interface ButtonProps {
          title: string;
      }

      export const ActionButton: React.FC<ButtonProps> = ({ title }) => {
          const [count, setCount] = useState(0);
          handleClick();
          return <button onClick={() => setCount(count + 1)}>{title}</button>;
      };

      export function resetCounter() {
          cleanup();
      }
    TSX

    symbols = Rubik::AST::Extractor.extract("button.tsx", tsx_code)
    names = symbols.map(&:name)

    assert_includes names, "ButtonProps"
    assert_includes names, "ActionButton"
    assert_includes names, "resetCounter"

    btn_sym = symbols.find { |s| s.name == "ActionButton" }
    assert_equal :function, btn_sym.kind
    assert_includes btn_sym.calls, "useState"
    assert_includes btn_sym.calls, "handleClick"
  end

  def test_python_async_and_docstring_extraction
    py_code = <<~PY
      import asyncio

      class Worker:
          """Worker documentation."""
          async def process(self, item):
              # comment mentioning foo()
              await do_work(item)
              return item

      async def run():
          w = Worker()
          await w.process(1)
    PY

    symbols = Rubik::AST::Extractor.extract("worker.py", py_code)
    names = symbols.map(&:name)

    assert_includes names, "import asyncio"
    assert_includes names, "Worker"
    assert_includes names, "Worker.process"
    assert_includes names, "run"

    worker_sym = symbols.find { |s| s.name == "Worker" }
    assert_equal "Worker documentation.", worker_sym.docstring

    proc_sym = symbols.find { |s| s.name == "Worker.process" }
    assert_includes proc_sym.calls, "do_work"
    refute_includes proc_sym.calls, "foo"
  end

  def test_graceful_fallback_when_treesitter_fails
    code = <<~GO
      package main
      type Config struct { Port int }
      func Start() {}
    GO

    # Temporarily force TreeSitterExtractor to fail to test fallback
    Rubik::AST::TreeSitterExtractor.stub(:extract, nil) do
      symbols = Rubik::AST::Extractor.extract("service.go", code)
      names = symbols.map(&:name)
      assert_includes names, "Config"
      assert_includes names, "Start"
    end
  end

  def test_deeply_nested_ast_traversal_resilience
    # Deeply nested call expression that would crash recursive walkers with SystemStackError
    nested_expr = "a#{'()' * 3000}"
    code = "def deeply_nested():\n    #{nested_expr}\n"

    symbols = Rubik::AST::Extractor.extract("deep.py", code)
    names = symbols.map(&:name)
    assert_includes names, "deeply_nested"
  end

  def test_invalid_utf8_encoding_resilience
    # Malformed bytes inside code that would trigger ArgumentError: invalid byte sequence
    bad_code = "def resilient_function():\n    return 42\n\xFF\xFE bad bytes"
    symbols = Rubik::AST::Extractor.extract("bad.py", bad_code)
    names = symbols.map(&:name)
    assert_includes names, "resilient_function"
  end

  def test_signature_truncation_for_massive_lines
    # Massive single-line function header to prevent context window bloat
    massive_params = (1..50).map { |i| "param_#{i}: VeryLongTypeName#{i}" }.join(", ")
    code = "def massive_signature(#{massive_params}):\n    pass\n"

    symbols = Rubik::AST::Extractor.extract("massive.py", code)
    sym = symbols.find { |s| s.name == "massive_signature" }
    assert sym
    assert sym.signature.end_with?("...")
    assert sym.signature.length <= 303
  end
end
