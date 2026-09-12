# frozen_string_literal: true

module Rubik
  module Skills
    # One collected validation problem. +level+ separates fatal rejections
    # (:error — the skill is skipped) from non-fatal deviations (:warning —
    # the skill is accepted and the note is surfaced by !skill).
    ValidationIssue = Struct.new(:path, :field, :message, :level, keyword_init: true) do
      def error?   = level == :error
      def warning? = level == :warning
    end

    # agentskills.io frontmatter validation, spec-strict: fatal violations of
    # the required fields (name, description) reject the skill; deviations in
    # optional/experimental fields (metadata, allowed-tools, unknown keys)
    # degrade to warnings. One bad skill never aborts a discovery scan.
    class Validator
      NAME_RE           = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze # no lead/trail/double hyphen
      MAX_NAME          = 64
      MAX_DESCRIPTION   = 1024
      MAX_COMPATIBILITY = 500
      KNOWN_KEYS        = %w[name description license compatibility metadata allowed-tools].freeze

      class << self
        # => [Skill, Array<ValidationIssue>] — the Skill is nil when a fatal
        # issue exists; the issue array carries fatal issues + warnings.
        def validate(dir_name:, root:, scope:, path:, frontmatter:)
          fatal = []
          warnings = []

          name = frontmatter["name"].to_s
          description = frontmatter["description"].to_s.strip

          fatal << build_issue(path, :name, "is required") if name.empty?
          unless name.empty? || (name.length <= MAX_NAME && NAME_RE.match?(name))
            fatal << build_issue(path, :name,
                                 "'#{name}' must be 1-#{MAX_NAME} characters of [a-z0-9-], " \
                                 "no leading/trailing/double hyphen")
          end
          fatal << build_issue(path, :name, "'#{name}' must equal its directory name '#{dir_name}'") if !name.empty? && name != dir_name

          fatal << build_issue(path, :description, "is required (1-#{MAX_DESCRIPTION} characters)") if description.empty?
          if !description.empty? && description.length > MAX_DESCRIPTION
            fatal << build_issue(path, :description, "exceeds #{MAX_DESCRIPTION} characters")
          end

          license = optional_string(frontmatter["license"], "license", path, warnings)
          compatibility = optional_string(frontmatter["compatibility"], "compatibility", path, warnings)
          if compatibility.to_s.length > MAX_COMPATIBILITY
            fatal << build_issue(path, :compatibility, "exceeds #{MAX_COMPATIBILITY} characters")
          end

          metadata = parse_metadata(frontmatter["metadata"], path, fatal)
          allowed_tools = parse_allowed_tools(frontmatter["allowed-tools"], path, warnings)

          (frontmatter.keys - KNOWN_KEYS).each do |key|
            warnings << build_issue(path, key.to_sym, "unknown frontmatter key ignored", :warning)
          end

          issues = fatal + warnings
          return [nil, issues] if fatal.any?

          [Skill.new(
            name: name, description: description, scope: scope, root: root,
            license: license, compatibility: compatibility,
            metadata: metadata.freeze, allowed_tools: allowed_tools.freeze,
            warnings: warnings.freeze
          ), issues]
        end

      private

      # Fatal rejections default to :error; callers collecting warnings pass
      # :warning explicitly.
      def build_issue(path, field, message, level = :error)
        ValidationIssue.new(path: path, field: field, message: message, level: level)
      end

      def optional_string(raw, key, path, warnings)
        return nil if raw.nil?
        return raw if raw.is_a?(String)

        warnings << build_issue(path, key.to_sym, "ignored: must be a string", :warning)
        nil
      end

        # Spec: "a map from string keys to string values" — any deviation is
        # fatal (matches the skills-ref reference validator's strictness).
        def parse_metadata(raw, path, fatal)
          return {} if raw.nil?

          unless raw.is_a?(Hash) && raw.keys.all? { |k| k.is_a?(String) } && raw.values.all? { |v| v.is_a?(String) }
            fatal << build_issue(path, :metadata, "must be a map from string keys to string values")
            return {}
          end
          raw
        end

        # Spec (experimental): "a space-separated string of pre-approved
        # tools". Parsed and displayed only — never enforced. An Array form
        # degrades to a warning (accepted for interoperability).
        def parse_allowed_tools(raw, path, warnings)
          case raw
          when nil
            []
          when String
            raw.split(/\s+/).reject(&:empty?)
          when Array
            warnings << build_issue(path, :"allowed-tools",
                                    "given as a list; the spec declares a space-separated string", :warning)
            raw.map(&:to_s)
          else
            warnings << build_issue(path, :"allowed-tools", "ignored: must be a space-separated string", :warning)
            []
          end
        end
      end
    end
  end
end
