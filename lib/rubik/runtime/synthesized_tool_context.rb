# frozen_string_literal: true

require_relative "../coeffects"
require_relative "context"
require_relative "sealed_coeffects"

module Rubik
  module Runtime
    # Sealed read-only execution context for synthesized and overlay tools (Pillar 2 / Pillar 3).
    #
    # Modeled after `Rubik::REPL::SynthesizedCommandContext`. Exposes ONLY read-only coeffect
    # accessors (`require`, `get`, `has?`, `satisfied?`, `coeffect`).
    #
    # All mutating/lifecycle/parent methods (`dispose`, `provide`, `unprovide`, `parent`,
    # `extend`, `register_disposable`, `on_dispose`, etc.) are blocked with NoMethodError.
    class SynthesizedToolContext
      include SealedCoeffects

      # Positional parameter kinds accepted as evidence of a 2-arity handler.
      POSITIONAL_KINDS = [:req, :opt, :rest].freeze

      # Remove Object#extend so calling ctx.extend raises NoMethodError
      undef_method :extend

      class << self
        # Idempotently wrap an existing context in a sealed SynthesizedToolContext.
        def wrap(context)
          return context if context.is_a?(self)

          new(context)
        end

        # Determines whether a tool handler expects or permits context as its 2nd argument.
        #
        # Evaluates positional parameter count (:req, :opt, :rest), ignoring keyword
        # and block parameters.
        def accepts_context?(handler)
          return false unless handler.respond_to?(:call)

          params = if handler.respond_to?(:parameters)
                     handler.parameters
                   elsif handler.respond_to?(:method)
                     begin
                       handler.method(:call).parameters
                     rescue StandardError
                       []
                     end
                   else
                     []
                   end

          if params.empty?
            return handler.arity == 2 if handler.respond_to?(:arity)

            return false
          end

          # params is an Array of [type, name] pairs (Method#parameters), so a
          # Hash-style slice would be wrong here — filter by positional kinds.
          pos_params = params.select { |param| POSITIONAL_KINDS.include?(param[0]) }
          req_count = pos_params.count { |param| param[0] == :req }

          2.between?(req_count, pos_params.size)
        end
      end

      def initialize(context = nil)
        @context = context
      end

      # Safe read-only coeffect dependency resolution.
      def require(name)
        raise CoeffectMissingError, "Required coeffect '#{name}' is not satisfied in the context." if name.nil?

        key = name.to_s.downcase.strip
        raise CoeffectBlockedError, "Required coeffect '#{key}' is denied by sealed-context policy." if blocked?(key)

        val = get(name)
        return val unless val.nil?

        raise CoeffectMissingError, "Required coeffect '#{name}' is not satisfied in the context."
      end

      # Safe mediated coeffect reader.
      def get(name, default = nil)
        return default if name.nil?

        key = name.to_s.downcase.strip
        return default if blocked?(key)

        val = if @context.respond_to?(:get)
                res = @context.get(key)
                res = @context.get(name) if res.nil? && name.to_s != key
                res
              elsif @context.is_a?(Hash)
                @context[key] || @context[name] || @context[name.to_s] || @context[name.to_sym]
              elsif @context.respond_to?(:resolve)
                @context.resolve(key)
              elsif @context.respond_to?(:[])
                @context[key] || @context[name]
              end

        val.nil? ? default : val
      end

      def has?(name)
        return false if name.nil?

        # get denies blocked keys (returns the default), so a single gate is
        # enough and the denial logs once.
        !get(name).nil?
      end

      def satisfied?(dependencies)
        Array(dependencies).all? { |dep| has?(dep) }
      end

      def coeffect(name)
        get(name)
      end
    end
  end
end
