# frozen_string_literal: true

require "json"
require_relative "../../coeffects"

module Rubik
  module Orchestrator
    module Subagent
      class ProfileValidationError < ArgumentError
        attr_reader :errors

        def initialize(errors)
          @errors = errors.map(&:freeze).freeze
          super(JSON.generate(to_h))
        end

        def to_h
          { "error" => "invalid_subagent_profile", "errors" => @errors }
        end
      end

      # Validates the model-facing archetype contract before the registry can
      # observe it. Tool grants expand only to the existing declaration groups.
      module ProfileContract
        FIELD_LIMITS = { name: 64, description: 500, system_prompt: 12_000 }.freeze
        MAX_COEFFECTS = 16
        MAX_COEFFECT_LENGTH = 64
        MAX_GRANTS = 2
        CAPABILITY_GRANTS = ["write", "subagent_spawn"].map(&:freeze).freeze
        UNSET = Object.new.freeze

        KNOWN_COEFFECTS = Rubik::Coeffects.constants(false).filter_map do |constant|
          value = Rubik::Coeffects.const_get(constant, false)
          Rubik::Coeffects.canonical(value) if value.is_a?(String)
        end.uniq.freeze

        Profile = Struct.new(:name, :description, :system_prompt, :requires, :grants, keyword_init: true)

        module_function

        def validate(name:, description:, system_prompt:, requires: [], grants: UNSET,
                     enable_write_tools: nil, enable_subagent_tools: nil, reserved_names: [], override_requested: false)
          errors = []
          profile_name = normalize_text(name, :name, errors, allow_symbol: true)
          profile_description = normalize_text(description, :description, errors)
          profile_prompt = normalize_text(system_prompt, :system_prompt, errors)

          errors << error("name", "too_long", "Name must be at most #{FIELD_LIMITS.fetch(:name)} characters.") if profile_name.length > FIELD_LIMITS.fetch(:name)
          if profile_description.length > FIELD_LIMITS.fetch(:description)
            errors << error("description", "too_long", "Description must be at most #{FIELD_LIMITS.fetch(:description)} characters.")
          end
          if profile_prompt.length > FIELD_LIMITS.fetch(:system_prompt)
            errors << error("system_prompt", "too_long", "System prompt must be at most #{FIELD_LIMITS.fetch(:system_prompt)} characters.")
          end

          reserved = Array(reserved_names).map { |reserved_name| reserved_name.to_s.strip.downcase }
          if reserved.include?(profile_name.downcase)
            detail = override_requested ? " even when an override flag is supplied" : ""
            errors << error("name", "reserved_name", "built-in system archetypes are reserved#{detail}.")
          end

          normalized_requires = normalize_list(
            requires, field: "requires", allowed: KNOWN_COEFFECTS, maximum: MAX_COEFFECTS,
                      unknown_code: "unknown_coeffect", duplicate_code: "duplicate_coeffect", errors: errors
          ) do |value|
            Rubik::Coeffects.canonical(value)
          end

          normalized_grants = normalize_grants(
            grants, enable_write_tools, enable_subagent_tools, errors
          )

          raise ProfileValidationError, errors unless errors.empty?

          Profile.new(
            name: profile_name, description: profile_description, system_prompt: profile_prompt,
            requires: normalized_requires.map(&:freeze).freeze, grants: normalized_grants.map(&:freeze).freeze
          )
        end

        def tool_filter(grants)
          enabled = grants.freeze
          write_tools = Rubik::Tools::Catalog.write_grant_tools
          spawn_tools = Rubik::Tools::Catalog.spawn_tools

          lambda do |tool_name|
            next false if write_tools.include?(tool_name) && !enabled.include?("write")
            next false if spawn_tools.include?(tool_name) && !enabled.include?("subagent_spawn")

            true
          end
        end

        def normalize_text(value, field, errors, allow_symbol: false)
          if value.nil?
            errors << error(field.to_s, "required", "#{field} is required.")
            return ""
          end

          valid_type = value.is_a?(String) || (allow_symbol && value.is_a?(Symbol))
          unless valid_type
            errors << error(field.to_s, "invalid_type", "#{field} must be a string.")
            return ""
          end

          normalized = value.to_s.strip
          errors << error(field.to_s, "required", "#{field} must not be empty.") if normalized.empty?
          normalized
        end
        private_class_method :normalize_text

        def normalize_list(values, field:, allowed:, maximum:, unknown_code:, duplicate_code:, errors:)
          unless values.is_a?(Array)
            errors << error(field, "invalid_type", "#{field} must be an array of strings.")
            return []
          end

          errors << error(field, "too_many_values", "#{field} may contain at most #{maximum} values.") if values.length > maximum

          normalized = values.filter_map.with_index do |value, index|
            unless value.is_a?(String) || value.is_a?(Symbol)
              errors << error(field, "invalid_type", "#{field}[#{index}] must be a string.")
              next
            end

            text = value.to_s.strip.downcase
            if field == "requires" && text.length > MAX_COEFFECT_LENGTH
              errors << error(field, "too_long", "#{field}[#{index}] must be at most #{MAX_COEFFECT_LENGTH} characters.")
              next
            end

            key = yield(text)
            if key.empty?
              errors << error(field, "empty_value", "#{field}[#{index}] must not be empty.")
              next
            end
            unless allowed.include?(key)
              errors << error(field, unknown_code, "#{field}[#{index}] is not in the allowlist.")
              next
            end

            key
          end

          duplicates = normalized.tally.select { |_value, count| count > 1 }.keys
          duplicates.each do |duplicate|
            errors << error(field, duplicate_code, "#{field} contains duplicate value '#{duplicate}'.")
          end
          normalized
        end
        private_class_method :normalize_list

        def normalize_grants(grants, enable_write_tools, enable_subagent_tools, errors)
          legacy = {
            "write" => enable_write_tools,
            "subagent_spawn" => enable_subagent_tools
          }
          legacy_present = legacy.values.any? { |value| !value.nil? }

          unless grants.equal?(UNSET)
            errors << error("grants", "conflicting_grant_sources", "Use grants or legacy enable_* flags, not both.") if legacy_present
            return normalize_list(
              grants, field: "grants", allowed: CAPABILITY_GRANTS, maximum: MAX_GRANTS,
                      unknown_code: "unknown_grant", duplicate_code: "duplicate_grant", errors: errors
            ) { |value| value }
          end

          legacy.each_with_object([]) do |(grant, value), normalized|
            next if value.nil?

            unless [true, false].include?(value)
              errors << error("grants", "invalid_legacy_grant", "Legacy capability flags must be booleans.")
              next
            end
            normalized << grant if value
          end
        end
        private_class_method :normalize_grants

        def error(field, code, message)
          { "field" => field, "code" => code, "message" => message }
        end
        private_class_method :error
      end
    end
  end
end
