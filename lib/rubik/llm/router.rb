# frozen_string_literal: true

require_relative "registry"

module Rubik
  module LLM
    class Router
      HEAVY_KEYWORDS = %w[plan goal architect architecture refactor redesign benchmark security optimize].freeze
      FAST_KEYWORDS = %w[syntax typo lint diagnose format quick check helper].freeze

      attr_reader :config, :registry

      def initialize(config:, registry: nil)
        @config = config
        @registry = registry || Registry.new
      end

      def route(task_type: :auto, prompt: "")
        mode = @config.fetch("router.mode", "auto").to_s.downcase
        role = determine_role(task_type, prompt, mode)
        spec = @config.model_spec(role)

        provider = @registry.get_for(spec)
        unless provider
          fallback_spec = @config.model_spec(:default)
          provider = @registry.get_for(fallback_spec) || @registry.get("ollama")
          spec = fallback_spec
        end

        {
          provider: provider,
          model: spec["name"],
          role: role,
          spec: spec
        }
      end

      def available_roles
        %i[default fast advanced]
      end

      private

      def determine_role(task_type, prompt, mode)
        case task_type.to_sym
        when :fast, :quick, :repair, :diagnose
          :fast
        when :advanced, :plan, :goal, :refactor
          :advanced
        when :default
          :default
        else
          return :default if mode == "manual"

          classify_prompt(prompt)
        end
      end

      def classify_prompt(prompt)
        text = prompt.to_s.downcase

        return :advanced if HEAVY_KEYWORDS.any? { |kw| text.include?(kw) }
        return :fast if FAST_KEYWORDS.any? { |kw| text.include?(kw) }

        :default
      end
    end
  end
end
