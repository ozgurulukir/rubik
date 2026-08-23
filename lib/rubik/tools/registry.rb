# frozen_string_literal: true

require_relative "base"

module Rubik
  module Tools
    class Registry
      def initialize
        @tools = {}
      end

      def register(tool_instance)
        @tools[tool_instance.name] = tool_instance
      end

      def get(tool_name)
        @tools[tool_name]
      end

      def list
        @tools.values
      end

      def schemas
        @tools.values.map(&:to_h)
      end
    end
  end
end
