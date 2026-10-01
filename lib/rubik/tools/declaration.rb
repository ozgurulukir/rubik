# frozen_string_literal: true

module Rubik
  module Tools
    # One tool, one declaration (architecture review 2026-10-01, candidate 1):
    # the COMPLETE interface + policy of a tool as a single frozen literal in
    # the tool's domain file. Registry order, archetype allowlists, the
    # maestro gate, the custom-type write gate, TOOLS.md and prompt teachings
    # all derive from this object via Tools::Catalog.
    #
    # Policy fields are orchestrator-plane facts. They NEVER leak into the
    # LLM schema surface: BaseTool#to_h keeps emitting exactly
    # name/description/risk/parameters (invariant-pinned by
    # test_tool_declaration_catalog).
    Declaration = Struct.new(
      :name, :aliases, :description, :risk, :params_schema,
      :allow_additional_properties,
      :archetypes,      # Array<Symbol> subset of [:research, :coder] — subagent allowlists
      :subagent_spawn,  # bool — member of the spawn set (self-archetype recursion guard)
      :write_grant,     # bool — denied to custom types lacking enable_write_tools
      :maestro_blocked, # true | false | nil — gate class; MUST be explicit for :write/:execute
      keyword_init: true
    ) do
      def initialize(name:, description:, risk: :read, params_schema: {}, aliases: [],
                     allow_additional_properties: true, archetypes: [], subagent_spawn: false,
                     write_grant: false, maestro_blocked: nil)
        clean_name = name.to_s
        # Leading digits are tolerated (not required) for legacy dynamic
        # tools: synthesis/overlay normalize to lowercase snake but do not
        # strip a leading digit, and LLM provider tool-name rules allow
        # digits — rejecting them would drop tools that loaded before the
        # Declaration seam existed.
        unless clean_name.match?(/\A[a-z0-9_]+\z/)
          raise ArgumentError,
                "tool name '#{clean_name}' must be lowercase snake_case (a-z, 0-9, _) — canonical names are the registry keys"
        end

        risk_key = risk.to_s.to_sym
        unless [:read, :write, :execute].include?(risk_key)
          raise ArgumentError,
                "tool '#{clean_name}' risk must be one of read, write, execute (got #{risk.inspect})"
        end

        archetype_keys = Array(archetypes).map { |a| a.to_s.to_sym }
        unknown = archetype_keys - [:research, :coder]
        if unknown.any?
          raise ArgumentError,
                "tool '#{clean_name}' archetypes must be a subset of research, coder (got #{unknown.join(', ')}) — " \
                "empty means orchestrator-plane only"
        end

        # Members are shared by every instance of the class (the DECLARATION
        # constant): freeze aliases and the schema's outer hash so no caller
        # can corrupt the projection source for the whole process.
        # (to_h dups before injecting additionalProperties, so the frozen
        # schema never blocks the LLM payload path.)
        schema = params_schema.is_a?(Hash) ? params_schema.freeze : params_schema
        super(
          name: clean_name,
          description: description.to_s,
          risk: risk_key,
          params_schema: schema,
          aliases: Array(aliases).map(&:to_s).freeze,
          allow_additional_properties: allow_additional_properties,
          archetypes: archetype_keys.freeze,
          subagent_spawn: subagent_spawn ? true : false,
          write_grant: write_grant ? true : false,
          maestro_blocked: if maestro_blocked.nil?
                             nil
                           else
                             (maestro_blocked ? true : false)
                           end
        )
        freeze
      end

      # Derived copy with overrides (e.g. invoke_subagent's supervisor-derived
      # schema) — states a near-declaration instead of splatting to_h by hand.
      def with(**overrides)
        Declaration.new(**to_h, **overrides)
      end

      def maestro_blocked? = maestro_blocked == true

      def spawn? = subagent_spawn == true

      def write_grant? = write_grant == true
    end
  end
end
