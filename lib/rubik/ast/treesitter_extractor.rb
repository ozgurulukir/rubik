# frozen_string_literal: true

begin
  require "tree_sitter_language_pack"
  TREE_SITTER_AVAILABLE = true
rescue LoadError
  TREE_SITTER_AVAILABLE = false
end

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

        def extract(file_path, content = nil)
          return nil unless available?

          ext = File.extname(file_path).downcase
          mapping = LANGUAGE_MAP[ext]
          return nil unless mapping

          code = content || (File.exist?(file_path) ? File.read(file_path) : "")
          return [] if code.empty?

          code = code.encode("UTF-8", invalid: :replace, undef: :replace) unless code.valid_encoding?

          parser = parser_for(mapping[:parser])
          return nil unless parser

          tree = parser.parse(code)
          return nil unless tree&.root_node

          walker = mapping[:walker].new(file_path, code)
          walker.walk(tree.root_node)
        rescue StandardError, SystemStackError, ScriptError => e
          warn "[WARN] TreeSitter extraction failed for #{file_path}: #{e.message}" if ENV["RUBIK_DEBUG"]
          nil
        end
      end
    end
  end
end
