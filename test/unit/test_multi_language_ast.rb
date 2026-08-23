# frozen_string_literal: true

require_relative "../test_helper"

class TestMultiLanguageAST < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @graph = Rubik::AST::Graph.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_go_ast_extractor
    go_code = <<~GO
      package main

      import (
        "fmt"
        "net/http"
      )

      type User struct {
        Name string
        Age  int
      }

      type Greeter interface {
        Greet() string
      }

      func (u *User) Greet() string {
        fmt.Println("Hello")
        return u.Name
      }

      func Main() {
        u := &User{Name: "Rubik"}
        u.Greet()
      }
    GO

    symbols = Rubik::AST::GoExtractor.extract("main.go", go_code)
    names = symbols.map(&:name)

    assert_includes names, "import (...)"
    assert_includes names, "User"
    assert_includes names, "Greeter"
    assert_includes names, "(u *User).Greet"
    assert_includes names, "Main"

    greet_sym = symbols.find { |s| s.name == "(u *User).Greet" }
    assert_equal :function, greet_sym.kind
    assert_includes greet_sym.calls, "Println"
  end

  def test_rust_ast_extractor
    rs_code = <<~RS
      use std::collections::HashMap;

      pub struct Config {
          pub host: String,
      }

      pub enum State {
          Running,
          Stopped,
      }

      impl Config {
          pub fn new(host: String) -> Self {
              println!("Init config");
              Config { host }
          }
      }

      fn process() {
          let c = Config::new("localhost".to_string());
      }
    RS

    symbols = Rubik::AST::RustExtractor.extract("lib.rs", rs_code)
    names = symbols.map(&:name)

    assert_includes names, "use std::collections::HashMap"
    assert_includes names, "Config"
    assert_includes names, "State"
    assert_includes names, "Config::new"
    assert_includes names, "process"

    new_fn = symbols.find { |s| s.name == "Config::new" }
    assert_equal :function, new_fn.kind
    assert_includes new_fn.calls, "println"
  end

  def test_zig_ast_extractor
    zig_code = <<~ZIG
      const std = @import("std");

      pub const Buffer = struct {
          data: []u8,
      };

      pub fn initBuffer(allocator: std.mem.Allocator) Buffer {
          std.debug.print("init", .{});
          return Buffer{ .data = &[_]u8{} };
      }
    ZIG

    symbols = Rubik::AST::ZigExtractor.extract("buffer.zig", zig_code)
    names = symbols.map(&:name)

    assert_includes names, "const std = @import(\"std\")"
    assert_includes names, "Buffer"
    assert_includes names, "initBuffer"

    init_fn = symbols.find { |s| s.name == "initBuffer" }
    assert_equal :function, init_fn.kind
  end

  def test_c_ast_extractor
    c_code = <<~C
      #include <stdio.h>
      #include "config.h"

      typedef struct Point {
          int x;
          int y;
      } Point;

      int add_points(Point a, Point b) {
          printf("Adding\\n");
          return a.x + b.x;
      }
    C

    symbols = Rubik::AST::CExtractor.extract("point.c", c_code)
    names = symbols.map(&:name)

    assert_includes names, "#include <stdio.h>"
    assert_includes names, "Point"
    assert_includes names, "add_points"

    add_fn = symbols.find { |s| s.name == "add_points" }
    assert_equal :function, add_fn.kind
  end

  def test_python_ast_extractor
    py_code = <<~PY
      import os
      from pathlib import Path

      class Calculator:
          def __init__(self):
              self.total = 0

          def add(self, a, b):
              print("adding")
              return a + b

      def main():
          calc = Calculator()
          calc.add(2, 3)
    PY

    symbols = Rubik::AST::PythonExtractor.extract("calc.py", py_code)
    names = symbols.map(&:name)

    assert_includes names, "import os"
    assert_includes names, "from pathlib import Path"
    assert_includes names, "Calculator"
    assert_includes names, "Calculator.__init__"
    assert_includes names, "Calculator.add"
    assert_includes names, "main"

    add_fn = symbols.find { |s| s.name == "Calculator.add" }
    assert_equal :function, add_fn.kind
  end

  def test_graph_multi_language_cross_indexing
    @graph.index_file("src/main.go", "package main\nfunc RunApp() {}\n")
    @graph.index_file("src/lib.rs", "pub fn start_kernel() {}\n")
    @graph.index_file("src/engine.zig", "pub fn process_data() {}\n")
    @graph.index_file("src/driver.c", "void init_driver() {}\n")
    @graph.index_file("src/agent.py", "def execute_task():\n    pass\n")

    assert @graph.symbols.key?("RunApp")
    assert @graph.symbols.key?("start_kernel")
    assert @graph.symbols.key?("process_data")
    assert @graph.symbols.key?("init_driver")
    assert @graph.symbols.key?("execute_task")

    @graph.remove_file("src/main.go")
    refute @graph.symbols.key?("RunApp")
    assert @graph.symbols.key?("start_kernel")
  end
end
