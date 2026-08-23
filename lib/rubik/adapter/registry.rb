# frozen_string_literal: true

require_relative "ruby"
require_relative "python"
require_relative "go"
require_relative "rust"
require_relative "c"
require_relative "zig"

module Rubik
  module Adapter
    class Registry
      def initialize
        @adapters = {
          "ruby" => RubyAdapter.new,
          "python" => PythonAdapter.new,
          "go" => GoAdapter.new,
          "rust" => RustAdapter.new,
          "c" => CAdapter.new,
          "zig" => ZigAdapter.new
        }
      end

      def get(lang_name)
        @adapters[lang_name.to_s.downcase]
      end

      def register(lang_name, adapter_instance)
        @adapters[lang_name.to_s.downcase] = adapter_instance
      end

      def list
        @adapters.keys
      end
    end
  end
end
