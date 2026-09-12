# frozen_string_literal: true

require_relative "frontmatter"
require_relative "skill"
require_relative "validator"

module Rubik
  module Skills
    DiscoveryResult = Struct.new(:skills, :issues, keyword_init: true)

    # The only discovery/scan layer of the skills subsystem (body reads live
    # in Manager#body, auxiliary listings in Skill#auxiliary_files). Pure
    # scanner: no lifecycle, no caching, no writers — it returns every
    # syntactically loadable skill (duplicates across scopes included);
    # precedence resolution lives in Registry#install. Per-directory failures
    # are collected as ValidationIssues and never abort the scan.
    class Storage
      attr_reader :project_root, :user_root, :extra_paths

      def initialize(root_dir:, home_dir:, extra_paths: [])
        @project_root = File.join(File.expand_path(root_dir.to_s), ".rubik", "skills")
        @user_root = home_dir ? File.join(File.expand_path(home_dir), ".rubik", "skills") : nil
        @extra_paths = Array(extra_paths).map { |p| File.expand_path(p.to_s) }
      end

      # Ordered discovery roots; earlier scopes win precedence in the
      # Registry: project > user > extra paths (declaration order).
      def scoped_roots
        roots = [{ root: @project_root, scope: SCOPE_PROJECT }]
        roots << { root: @user_root, scope: SCOPE_USER } if @user_root
        @extra_paths.each { |path| roots << { root: path, scope: SCOPE_EXTRA } }
        roots
      end

      # => DiscoveryResult(skills:, issues:)
      def discover(disabled: [])
        skills = []
        issues = []
        disabled_names = Array(disabled).map(&:to_s)

        scoped_roots.each do |target|
          next unless target[:root] && Dir.exist?(target[:root])

          Dir.children(target[:root]).sort.each do |dir_name|
            next if dir_name.start_with?(".")

            dir = File.join(target[:root], dir_name)
            next unless File.directory?(dir)

            path = File.join(dir, "SKILL.md")
            if disabled_names.include?(dir_name)
              issues << ValidationIssue.new(path: path, field: :disabled, message: "skipped (listed in skills.disabled)", level: :warning)
              next
            end
            unless File.file?(path)
              issues << ValidationIssue.new(path: path, field: :skill_md, message: "missing SKILL.md", level: :error)
              next
            end

            parsed = Frontmatter.parse(File.read(path))
            skill, skill_issues = Validator.validate(
              dir_name: dir_name, root: dir, scope: target[:scope], path: path, frontmatter: parsed[:frontmatter]
            )
            skills << skill if skill
            issues.concat(skill_issues)
          rescue Frontmatter::Error => e
            issues << ValidationIssue.new(path: path, field: :frontmatter, message: e.message, level: :error)
          rescue StandardError => e
            issues << ValidationIssue.new(path: path, field: :io, message: "#{e.class}: #{e.message}", level: :error)
          end
        end

        DiscoveryResult.new(skills: skills.freeze, issues: issues.freeze)
      end
    end
  end
end
