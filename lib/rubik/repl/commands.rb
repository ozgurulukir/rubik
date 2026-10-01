# frozen_string_literal: true

require_relative "commands/base"
require_relative "commands/system"
require_relative "commands/buffer"
require_relative "commands/session"
require_relative "commands/workspace"
require_relative "commands/lsp"
require_relative "commands/agent"
require_relative "commands/plugins"
require_relative "commands/mcp"
require_relative "commands/skills"
require_relative "commands/tasks"
require_relative "commands/subagents"
require_relative "commands/storage"
require_relative "commands/dmesg"

module Rubik
  module REPL
    module Commands
      MODULES = [
        System,
        Buffer,
        Session,
        Workspace,
        Lsp,
        Agent,
        Plugins,
        Mcp,
        Skills,
        Tasks,
        Subagents,
        Storage,
        Dmesg
      ].freeze

      def self.register_all(shell)
        MODULES.each { |mod| mod.register(shell) }
      end
    end
  end
end
