# frozen_string_literal: true

require_relative "ruby_extractor"
require_relative "go_extractor"
require_relative "rust_extractor"
require_relative "zig_extractor"
require_relative "c_extractor"
require_relative "python_extractor"
require_relative "typescript_extractor"

module Rubik
  module AST
    class Extractor
      EXTENSIONS = {
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

      def self.extract(file_path, content = nil)
        ext = File.extname(file_path).downcase
        extractor_class = EXTENSIONS[ext] || RubyExtractor
        extractor_class.extract(file_path, content)
      rescue StandardError => e
        # Graceful fallback to empty symbols on syntax/parsing anomalies
        []
      end

      def self.supported_extensions
        EXTENSIONS.keys
      end
    end
  end
end
