# frozen_string_literal: true

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
        ext = File.extname(file_path).downcase

        # 1. Ruby files: always use Prism-powered RubyExtractor first
        return RubyExtractor.extract(file_path, content) if ext == ".rb"

        # 2. Polyglot files: use Tree-Sitter AST extractor if available
        if TreeSitterExtractor.available? && TreeSitterExtractor.supports?(ext)
          symbols = TreeSitterExtractor.extract(file_path, content)
          return symbols unless symbols.nil?
        end

        # 3. Graceful Fallback: use legacy regex extractor
        extractor_class = FALLBACK_EXTRACTORS[ext] || RubyExtractor
        extractor_class.extract(file_path, content)
      rescue StandardError => e
        warn "[WARN] Extraction failed for #{file_path}: #{e.message}" if ENV["RUBIK_DEBUG"]
        # Graceful fallback to empty symbols on syntax/parsing anomalies
        []
      end

      def self.supported_extensions
        EXTENSIONS.keys
      end
    end
  end
end
