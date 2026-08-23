# frozen_string_literal: true

require_relative "llm/provider"
require_relative "llm/client"
require_relative "llm/openai_compatible"
require_relative "llm/ollama"
require_relative "llm/openai"
require_relative "llm/anthropic"
require_relative "llm/registry"
require_relative "llm/router"

module Rubik
  module LLM
  end
end
