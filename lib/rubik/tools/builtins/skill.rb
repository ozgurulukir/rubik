# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Level-2 progressive disclosure (agentskills.io): returns the full
    # SKILL.md body of one skill. Read-only — skills are data and are never
    # executed here; auxiliary scripts run through run_command like any file.
    #
    # Coeffect contract (AGENTS.md §2): declared via REQUIRES as
    # defense-in-depth — production registers this tool through
    # Skills::Manager#open_epoch!, which only runs after the skill_manager
    # coeffect is provided, but a direct/static registration (tests, future
    # hosts) stays PENDING (hidden from Registry#schemas) until the coeffect
    # is satisfied — the same gate ListFilesTool uses for context_index.
    class SkillTool < BaseTool
      NAME = "skill"
      REQUIRES = [Rubik::Coeffects::SKILL_MANAGER].freeze

      # Not in Catalog::BUILTINS — Skills::Manager#open_epoch! registers this
      # tool dynamically with its own ctx inverse; the declaration is real
      # wherever the tool is registered.
      DECLARATION = Declaration.new(
        name: NAME,
        description: "Load the full instructions of an agent skill by name. Available skills are listed in " \
                     "the <skills> system-prompt section. Call this before following a skill's guidance; " \
                     "files under its scripts/, references/ or assets/ directories are read with read_file " \
                     "relative to the returned skill directory.",
        risk: :read, maestro_blocked: false,
        params_schema: {
          type: "object",
          properties: {
            name: { type: "string", description: "Skill name exactly as listed in the <skills> section" }
          },
          required: ["name"]
        }
      )
      def initialize(manager = nil, runtime_context: nil)
        super(DECLARATION)
        @manager = manager
        @runtime_context = runtime_context
      end

      def execute(args = {})
        manager = Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::SKILL_MANAGER, @manager)
        return ToolOutput.error("Error: skills manager is not available.") unless manager
        return ToolOutput.error("Error: skills are disabled (skills.enabled = false).") unless manager.enabled?

        name = (args["name"] || args[:name]).to_s.strip
        available = manager.all.map(&:name)
        available_list = available.empty? ? "none" : available.join(", ")
        return ToolOutput.error("Error: `name` is required. Available skills: #{available_list}.") if name.empty?

        skill = manager.find(name)
        return ToolOutput.error("Error: unknown skill '#{name}'. Available skills: #{available_list}.") unless skill

        body = manager.body(name)
        return ToolOutput.error("Error: SKILL.md of '#{name}' could not be read (#{skill.path}).") if body.nil?

        ToolOutput.ok(<<~OUTPUT.strip)
          Skill '#{skill.name}' (scope: #{skill.scope}, directory: #{skill.root})
          Files referenced below (scripts/, references/, assets/) are read with read_file / run_command relative to that directory.
          ---
          #{body}
        OUTPUT
      end
    end
  end
end
