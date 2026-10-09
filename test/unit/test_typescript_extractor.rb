# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rubik/ast/symbol"
require_relative "../../lib/rubik/ast/typescript_extractor"

module Rubik
  module AST
    class TestTypeScriptExtractor < Minitest::Test
      def test_empty_content
        symbols = TypeScriptExtractor.extract("empty.ts", "")
        assert_equal [], symbols
      end

      def test_extract_imports
        code = <<~TS
          import { foo, bar } from "./module";
          import type { User } from "./types";
          import defaultExport from "lib";
          export { name } from "./other";
          const req = require("express");
        TS

        symbols = TypeScriptExtractor.extract("imports.ts", code)
        imports = symbols.select { |s| s.kind == :import }

        assert_equal 5, imports.size
        assert_equal 'import { foo, bar } from "./module"', imports[0].name
        assert_equal 'import type { User } from "./types"', imports[1].name
        assert_equal 'import defaultExport from "lib"', imports[2].name
        assert_equal 'export { name } from "./other"', imports[3].name
        assert_equal 'const req = require("express")', imports[4].name
      end

      def test_extract_multiline_import
        code = <<~TS
          import {
            a,
            b
          } from './multi';
        TS

        symbols = TypeScriptExtractor.extract("multiline.ts", code)
        assert_equal 1, symbols.size
        assert_equal :import, symbols[0].kind
        assert_equal 1, symbols[0].line_start
        assert_equal 4, symbols[0].line_end
      end

      def test_extract_class_interface_type
        code = <<~TS
          export abstract class Animal {
            abstract makeSound(): void;
          }

          interface User {
            id: number;
            name: string;
          }

          type ID = string | number;
        TS

        symbols = TypeScriptExtractor.extract("structures.ts", code)

        cls = symbols.find { |s| s.kind == :class }
        refute_nil cls
        assert_equal "Animal", cls.name
        assert_equal 1, cls.line_start
        assert_equal 3, cls.line_end

        iface = symbols.find { |s| s.kind == :interface }
        refute_nil iface
        assert_equal "User", iface.name
        assert_equal 5, iface.line_start
        assert_equal 8, iface.line_end

        type_alias = symbols.find { |s| s.kind == :type }
        refute_nil type_alias
        assert_equal "ID", type_alias.name
        assert_equal 10, type_alias.line_start
      end

      def test_extract_functions
        code = <<~TS
          function add(a: number, b: number): number {
            return a + b;
          }

          export const multiply = (a: number, b: number) => {
            return a * b;
          };

          const divide = function(a: number, b: number) {
            return a / b;
          };
        TS

        symbols = TypeScriptExtractor.extract("functions.ts", code)
        fn_names = symbols.map(&:name)

        assert_includes fn_names, "add"
        assert_includes fn_names, "multiply"
        assert_includes fn_names, "divide"
      end

      def test_extract_class_methods
        code = <<~TS
          class Person {
            private name: string;

            constructor(name: string) {
              this.name = name;
            }

            public getName(): string {
              return this.name;
            }

            public async updateName(newName: string): Promise<void> {
              this.name = newName;
            }
          }
        TS

        symbols = TypeScriptExtractor.extract("methods.ts", code)
        fn_names = symbols.select { |s| s.kind == :function }.map(&:name)

        assert_includes fn_names, "Person#constructor"
        assert_includes fn_names, "Person#getName"
        assert_includes fn_names, "Person#updateName"
      end

      def test_single_line_class_method_does_not_break_extraction
        code = <<~TS
          class Point {
            getX() { return this.x; }
            getY() { return this.y; }
          }
        TS

        symbols = TypeScriptExtractor.extract("single.ts", code)
        fn_names = symbols.select { |s| s.kind == :function }.map(&:name)

        assert_includes fn_names, "Point#getX"
        assert_includes fn_names, "Point#getY"
      end

      def test_extract_calls
        code = <<~TS
          function processUser(id: string) {
            validateId(id);
            const user = fetchUser(id);
            return user;
          }
        TS

        symbols = TypeScriptExtractor.extract("calls.ts", code)
        fn = symbols.find { |s| s.name == "processUser" }

        refute_nil fn
        assert_includes fn.calls, "validateId"
        assert_includes fn.calls, "fetchUser"
        refute_includes fn.calls, "return"
      end
    end
  end
end
