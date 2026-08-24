# frozen_string_literal: true

module Rubik
  module Tools
    class BaseTool
      attr_reader :name, :description, :risk, :params_schema, :aliases

      def initialize(name:, description:, risk: :read, params_schema: {}, aliases: [])
        @name = name
        @description = description
        @risk = risk # :read, :write, :execute
        @params_schema = params_schema
        @aliases = Array(aliases).map(&:to_s)
      end

      def execute(args = {})
        raise NotImplementedError
      end

      def to_h
        {
          name: @name,
          description: @description,
          risk: @risk,
          parameters: @params_schema
        }
      end
    end
  end
end
