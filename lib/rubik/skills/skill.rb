# frozen_string_literal: true

module Rubik
  module Skills
    # Immutable metadata record for one discovered skill (agentskills.io).
    # Data only: it never holds the SKILL.md body (read on demand via
    # Manager#body) and is never evaluated. One Struct instance per valid
    # skill directory; +warnings+ carries non-fatal frontmatter deviations.
    Skill = Struct.new(
      :name, :description, :scope, :root,
      :license, :compatibility, :metadata, :allowed_tools, :warnings,
      keyword_init: true
    ) do
      # Absolute path of the skill manifest.
      def path
        File.join(root, "SKILL.md")
      end

      # Files bundled under the conventional auxiliary directories
      # (level-3 progressive disclosure: the agent reads them on demand
      # with read_file / run_command relative to the skill directory).
      def auxiliary_files
        AUXILIARY_DIRS.filter_map do |sub|
          target = File.join(root, sub)
          [sub, Dir.children(target).sort] if Dir.exist?(target)
        end.to_h
      rescue StandardError => e
        Rubik::Platform.debug_warn("Failed to list auxiliary files for '#{name}': #{e.message}")
        {}
      end
    end
  end
end
