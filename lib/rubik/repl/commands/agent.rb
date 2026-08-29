# frozen_string_literal: true

require_relative "base"
require_relative "agent_providers"
require_relative "agent_models"
require_relative "agent_context"
require_relative "agent_execution"

module Rubik
  module REPL
    module Commands
      # Domain coordinator for Agent commands (Plan 60 D-6).
      # Decomposed into focused sub-modules:
      #   - AgentProviders: LLM provider registration and endpoint configuration
      #   - AgentModels: LLM model specifications and routing
      #   - AgentContext: Context limits, token compaction, verbosity, steps
      #   - AgentExecution: Plan, Goal, Test, Lint, Format, Sh execution
      module Agent
        extend Base

        def self.register(shell)
          AgentProviders.register(shell)
          AgentModels.register(shell)
          AgentContext.register(shell)
          AgentExecution.register(shell)
        end

        def self.sync_default_provider(shell)
          AgentModels.sync_default_provider(shell)
        end

        def self.parse_model_target(target, shell)
          AgentModels.parse_model_target(target, shell)
        end

        def self.parse_model_args(clean_args, shell)
          AgentModels.parse_model_args(clean_args, shell)
        end
      end
    end
  end
end
