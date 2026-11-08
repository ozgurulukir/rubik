# frozen_string_literal: true

require_relative "../coeffects"
require_relative "context"

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
      # Coeffects that must NEVER be leaked to synthesized tool code.
      BLOCKED_COEFFECTS = [
        "guard",
        "config",
        "sandbox",
        "sandbox_runner",
        "shell",
        "buffer_manager",
        "buffer",
        "runtime_manager",
        "task_manager",
        "tasks",
        "subagent_supervisor",
        "subagents",
        "subagent_pool",
        "init",
        "dispatcher",
        "commands"
      ].freeze

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
                     handler.method(:call).parameters rescue []
                   else
                     []
                   end

          if params.empty?
            return handler.arity == 2 if handler.respond_to?(:arity)
            return false
          end

          pos_params = params.select { |type, _| [:req, :opt, :rest].include?(type) }
          req_count = pos_params.count { |type, _| type == :req }

          req_count <= 2 && pos_params.size >= 2
        end
      end

      def initialize(context = nil)
        @context = context
      end

      # Safe read-only coeffect dependency resolution.
      def require(name)
        raise CoeffectMissingError, "Required coeffect '#{name}' is not satisfied in the context." if name.nil?

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

        key = name.to_s.downcase.strip
        return false if blocked?(key)

        !get(key).nil?
      end

      def satisfied?(dependencies)
        Array(dependencies).all? { |dep| has?(dep) }
      end

      def coeffect(name)
        get(name)
      end

      private

      def blocked?(key)
        canonical = if defined?(Rubik::Coeffects) && Rubik::Coeffects.respond_to?(:canonical)
                      Rubik::Coeffects.canonical(key)
                    else
                      key
                    end
        BLOCKED_COEFFECTS.include?(key) || BLOCKED_COEFFECTS.include?(canonical)
      end
    end
  end
end
