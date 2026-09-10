# frozen_string_literal: true

module Rubik
  module Plugin
    class Definition
      attr_reader :name, :version, :description, :inject, :requires, :factory_block

      def initialize(name, version: "1.0.0", description: "", inject: [], requires: [], &block)
        @name = name
        @version = version
        @description = description
        @inject = Array(inject)
        @requires = Array(requires)
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
  def self.plugin(name, version: "1.0.0", description: "", inject: [], requires: [], &)
    definition = Plugin::Definition.new(
      name,
      version: version,
      description: description,
      inject: inject,
      requires: requires,
      &
    )
    Plugin::Registry.register(definition)
  end
end
