# frozen_string_literal: true

module Rubik
  module Skills
    # Discovery scopes (precedence order: project > user > extra paths).
    SCOPE_PROJECT = :project
    SCOPE_USER    = :user
    SCOPE_EXTRA   = :extra

    # Conventional auxiliary directories of a skill (agentskills.io).
    AUXILIARY_DIRS = %w[scripts references assets].freeze
  end
end

require_relative "skills/skill"
require_relative "skills/frontmatter"
require_relative "skills/validator"
require_relative "skills/storage"
require_relative "skills/registry"
require_relative "skills/manager"
