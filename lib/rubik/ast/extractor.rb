# frozen_string_literal: true

require_relative "extraction_result"
require_relative "ruby_extractor"
require_relative "go_extractor"
require_relative "rust_extractor"
require_relative "zig_extractor"
require_relative "c_extractor"
require_relative "python_extractor"
require_relative "typescript_extractor"
require_relative "treesitter_extractor"

module Rubik
  module AST
    class Extractor
      FALLBACK_EXTRACTORS = {
        ".rb" => RubyExtractor,
        ".go" => GoExtractor,
        ".rs" => RustExtractor,
        ".zig" => ZigExtractor,
        ".c" => CExtractor,
        ".h" => CExtractor,
        ".cpp" => CExtractor,
        ".hpp" => CExtractor,
        ".py" => PythonExtractor,
        ".ts" => TypeScriptExtractor,
        ".tsx" => TypeScriptExtractor,
        ".js" => TypeScriptExtractor,
        ".jsx" => TypeScriptExtractor
      }.freeze

      EXTENSIONS = FALLBACK_EXTRACTORS

      def self.extract(file_path, content = nil)
        extract_result(file_path, content).symbols
      end

      # Structured outcome (issue #147): symbols plus status/source/detail, so
      # a failed extraction is distinguishable from a legitimately empty file
      # and from a degraded regex fallback. Status vocabulary lives in
      # AST::ExtractionResult.
      def self.extract_result(file_path, content = nil)
        ext = File.extname(file_path).downcase

        # 1. Ruby files: always use Prism-powered RubyExtractor first
        if ext == ".rb"
          return ExtractionResult.new(symbols: RubyExtractor.extract(file_path, content),
                                      status: :ok, source: :ruby)
        end

        # 2. Polyglot files: use the Tree-Sitter AST extractor if available
        if TreeSitterExtractor.available? && TreeSitterExtractor.supports?(ext)
          ts = TreeSitterExtractor.extract_result(file_path, content)
          if ts.trustworthy?
            return ExtractionResult.new(symbols: ts.symbols, status: ts.status,
                                        source: :tree_sitter, detail: ts.detail)
          end

          # The language parser failed (crash / unparsable): the regex
          # fallback is best-effort only, and the status says so.
          return fallback_result(file_path, content, ext, status: :failed, detail: ts.detail) if ts.failed?
        end

        # 3. Graceful fallback: the legacy regex extractor — the primary path
        # in environments without the tree-sitter pack or for extensions no
        # language extractor claims (:unavailable, legacy Ruby parse).
        fallback_result(file_path, content, ext)
      rescue StandardError, ScriptError => e
        warn "[WARN] Extraction failed for #{file_path}: #{e.class}: #{e.message}" if ENV["RUBIK_DEBUG"]
        ExtractionResult.new(symbols: [], status: :failed, source: :none, detail: "#{e.class}: #{e.message}")
      end

      def self.fallback_result(file_path, content, ext, status: nil, detail: nil)
        extractor = FALLBACK_EXTRACTORS[ext]
        status ||= extractor ? :ok : :unavailable
        symbols = (extractor || RubyExtractor).extract(file_path, content)
        ExtractionResult.new(symbols: symbols, status: status, source: :fallback, detail: detail)
      end

      def self.supported_extensions
        EXTENSIONS.keys
      end
    end
  end
end
