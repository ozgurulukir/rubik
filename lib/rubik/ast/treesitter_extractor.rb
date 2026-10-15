# frozen_string_literal: true

begin
  require "tree_sitter_language_pack"
  TREE_SITTER_AVAILABLE = true
rescue LoadError
  TREE_SITTER_AVAILABLE = false
end

require_relative "extraction_result"
require_relative "treesitter/base_walker"
require_relative "treesitter/python_walker"
require_relative "treesitter/go_walker"
require_relative "treesitter/rust_walker"
require_relative "treesitter/typescript_walker"
require_relative "treesitter/c_walker"
require_relative "treesitter/zig_walker"

module Rubik
  module AST
    class TreeSitterExtractor
      LANGUAGE_MAP = {
        ".py" => { parser: "python", walker: TreeSitter::PythonWalker },
        ".go" => { parser: "go", walker: TreeSitter::GoWalker },
        ".rs" => { parser: "rust", walker: TreeSitter::RustWalker },
        ".ts" => { parser: "typescript", walker: TreeSitter::TypeScriptWalker },
        ".tsx" => { parser: "tsx", walker: TreeSitter::TypeScriptWalker },
        ".js" => { parser: "javascript", walker: TreeSitter::TypeScriptWalker },
        ".jsx" => { parser: "javascript", walker: TreeSitter::TypeScriptWalker },
        ".c" => { parser: "c", walker: TreeSitter::CWalker },
        ".h" => { parser: "c", walker: TreeSitter::CWalker },
        ".cpp" => { parser: "cpp", walker: TreeSitter::CWalker },
        ".hpp" => { parser: "cpp", walker: TreeSitter::CWalker },
        ".zig" => { parser: "zig", walker: TreeSitter::ZigWalker }
      }.freeze

      class << self
        def available?
          TREE_SITTER_AVAILABLE && defined?(TreeSitterLanguagePack) && TreeSitterLanguagePack.respond_to?(:get_parser)
        end

        def supports?(ext)
          LANGUAGE_MAP.key?(ext.to_s.downcase)
        end

        def supported_extensions
          LANGUAGE_MAP.keys
        end

        def parser_for(lang_name)
          Thread.current[:rubik_ts_parsers] ||= {}
          Thread.current[:rubik_ts_parsers][lang_name] ||= TreeSitterLanguagePack.get_parser(lang_name)
        end

        def clear_parsers!
          Thread.current[:rubik_ts_parsers]&.clear
        end

        # Array-or-nil seam (unchanged contract for every existing caller):
        # nil means "fall back to the regex extractor".
        def extract(file_path, content = nil)
          result = extract_result(file_path, content)
          result.trustworthy? ? result.symbols : nil
        end

        # Structured outcome (issue #147): status :ok / :partial / :failed /
        # :unavailable plus best-effort symbols, so an empty result is never
        # confused with a broken parse. See AST::ExtractionResult.
        def extract_result(file_path, content = nil)
          return unavailable_result unless available?

          ext = File.extname(file_path).downcase
          mapping = LANGUAGE_MAP[ext]
          return unavailable_result unless mapping

          code = content || (File.exist?(file_path) ? File.read(file_path) : "")
          return ExtractionResult.new(symbols: [], status: :ok, source: :tree_sitter) if code.empty?

          code = code.encode("UTF-8", invalid: :replace, undef: :replace) unless code.valid_encoding?

          parser = parser_for(mapping[:parser])
          return failed_result("no parser for #{mapping[:parser]}") unless parser

          tree = parser.parse(code)
          return failed_result("parser returned no tree") unless tree&.root_node

          symbols = mapping[:walker].new(file_path, code).walk(tree.root_node) || []
          if root_has_error?(tree.root_node)
            return failed_result("tree-sitter reported syntax errors with no symbols") if symbols.empty?

            return ExtractionResult.new(symbols: symbols, status: :partial, source: :tree_sitter,
                                        detail: "tree-sitter reported syntax errors")
          end

          ExtractionResult.new(symbols: symbols, status: :ok, source: :tree_sitter)
        rescue StandardError, SystemStackError, ScriptError => e
          warn "[WARN] TreeSitter extraction failed for #{file_path}: #{e.message}" if ENV["RUBIK_DEBUG"]
          failed_result("#{e.class}: #{e.message}")
        end

        private

        def root_has_error?(node)
          if node.respond_to?(:has_error?)
            node.has_error?
          elsif node.respond_to?(:has_error)
            node.has_error
          end
        end

        def failed_result(detail)
          ExtractionResult.new(symbols: [], status: :failed, source: :none, detail: detail)
        end

        def unavailable_result
          ExtractionResult.new(symbols: [], status: :unavailable, source: :none)
        end
      end
    end
  end
end
