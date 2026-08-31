# frozen_string_literal: true

module Rubik
  module Plugin
    class Definition
      attr_reader :name, :version, :description, :inject, :factory_block

      def initialize(name, version: "1.0.0", description: "", inject: [], &block)
        @name = name
        @version = version
        @description = description
        @inject = Array(inject)
        @factory_block = block
      end
    end

    class Registry
      @definitions = {}

      class << self
        attr_reader :definitions

        def register(definition)
          @definitions[definition.name.to_s] = definition
        end

        def get(name)
          @definitions[name.to_s]
        end

        def clear!
          @definitions.clear
        end
      end
    end
  end

  # Top level DSL
  def self.plugin(name, version: "1.0.0", description: "", inject: [], &)
    definition = Plugin::Definition.new(
      name,
      version: version,
      description: description,
      inject: inject,
      &
    )
    Plugin::Registry.register(definition)
  end
end
