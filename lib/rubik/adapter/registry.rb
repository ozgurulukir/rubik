# frozen_string_literal: true

require "monitor"
require_relative "ruby"
require_relative "python"
require_relative "go"
require_relative "rust"
require_relative "c"
require_relative "zig"
require_relative "node"
require_relative "crystal"
require_relative "generic"

module Rubik
  module Adapter
    class Registry
      def initialize
        @monitor = Monitor.new
        node_adapter = NodeAdapter.new
        @adapters = {
          "ruby" => RubyAdapter.new,
          "python" => PythonAdapter.new,
          "go" => GoAdapter.new,
          "rust" => RustAdapter.new,
          "c" => CAdapter.new,
          "zig" => ZigAdapter.new,
          "crystal" => CrystalAdapter.new,
          "node" => node_adapter,
          "javascript" => node_adapter,
          "typescript" => node_adapter,
          "vue" => node_adapter
        }
      end

      def get(lang_name)
        @monitor.synchronize do
          @adapters[lang_name.to_s.downcase]
        end
      end

      def register(lang_name, adapter_instance)
        @monitor.synchronize do
          @adapters[lang_name.to_s.downcase] = adapter_instance
        end
      end

      def unregister(lang_name)
        @monitor.synchronize do
          @adapters.delete(lang_name.to_s.downcase)
        end
      end

      # Atomic hot-swap of an adapter.
      # Reentrant lock safety: Monitor#synchronize is explicitly reentrant (recursive),
      # allowing safe unregister and register invocation within the same critical section.
      def swap(lang_name, new_adapter)
        @monitor.synchronize do
          unregister(lang_name)
          register(lang_name, new_adapter) if new_adapter
        end
      end

      def list
        @monitor.synchronize do
          @adapters.keys.dup
        end
      end
    end
  end
end
