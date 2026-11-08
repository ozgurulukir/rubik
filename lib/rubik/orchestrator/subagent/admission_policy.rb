# frozen_string_literal: true

# No require of tools/catalog here: this file is loaded from inside the
# tools/builtins require chain (via profile_contract), and Catalog must not
# be re-entered mid-load. Every requiring module (scoped_registry,
# builtin_types) already requires catalog itself, and all Catalog reads
# happen at call time.
module Rubik
  module Orchestrator
    module Subagent
      # Single home for "what does plane P get?": the dynamic-origin vocabulary,
      # the risk ladder, the per-plane admission rule, and the capability labels
      # derived from the same rule. ScopedRegistry stays the executor; the
      # built-in archetypes and ProfileContract delegate here so the filters and
      # the labels the prompt prints cannot drift apart.
      module AdmissionPolicy
        module_function

        # Origins admitted through the risk ladder only; every other origin is
        # either the builtin catalog (gated by the plane's own name rule) or an
        # unknown registration kind that keeps its plane's default contract.
        DYNAMIC_ORIGINS = [:synthesis, :overlay].freeze
        MCP = :mcp
        RISK_LADDER = [:read, :write, :execute].freeze

        LABEL_FULL_CLONE = "full_clone"
        LABEL_READ_WRITE_TEST = "read_write_test"
        LABEL_READ_EXECUTE = "read_execute"
        LABEL_READ_ONLY = "read_only"

        # One risk-reading idiom for every consumer. Unknown (missing or
        # unrecognized) risk normalizes to nil, which no ladder admits —
        # admission fails closed everywhere.
        def risk_of(tool)
          tool.respond_to?(:risk) ? tool.risk.to_s.downcase.to_sym : nil
        end

        # The self archetype is the full-clone plane (its name is reserved, so
        # no custom type can collide with it). Every other arity-1-filtered
        # type lands on the custom plane: its own filter governs builtin names,
        # and this policy governs dynamic and MCP origins on top.
        def plane_for(type_def)
          self_plane?(type_def) ? :self : type_def
        end

        def self_plane?(type_def)
          type_def.respond_to?(:name) && type_def.name.to_s.downcase.strip == "self"
        end

        def allowed?(name, tool, origin, plane:)
          return false if Rubik::Tools::Catalog.orchestrator_only_tools.include?(name.to_s)

          case plane
          when :research then research_admits?(name, tool, origin)
          when :coder    then coder_admits?(name, tool, origin)
          when :self     then self_admits?(tool, origin)
          else                custom_admits?(tool, origin, write_grant?(plane))
          end
        end

        # Name-level grants formula for custom types over the builtin catalog.
        # The origin/risk gate is not folded in here: the executor applies it
        # through allowed? so one idiom covers every arity-1-filtered plane.
        def custom_tool_filter(grants)
          enabled = grants.freeze
          write_tools = Rubik::Tools::Catalog.write_grant_tools
          spawn_tools = Rubik::Tools::Catalog.spawn_tools

          lambda do |tool_name|
            next false if write_tools.include?(tool_name) && !enabled.include?("write")
            next false if spawn_tools.include?(tool_name) && !enabled.include?("subagent_spawn")

            true
          end
        end

        # Capability label for the plane's admitted toolset, simulated over the
        # builtin catalog with the type's own filter — the same predicate the
        # executor gates runtime admission with.
        def capability_label(type_def)
          return LABEL_FULL_CLONE if self_plane?(type_def)

          declarations = admitted_builtin_declarations(type_def)
          return LABEL_READ_WRITE_TEST if declarations.any?(&:write_grant?)
          return LABEL_READ_EXECUTE if declarations.any? { |declaration| risk_of(declaration) == :execute }

          LABEL_READ_ONLY
        end

        def research_admits?(name, tool, origin)
          return false if origin == MCP
          return risk_of(tool) == :read if DYNAMIC_ORIGINS.include?(origin)

          Rubik::Tools::Catalog.research_tools.include?(name.to_s)
        end

        def coder_admits?(name, tool, origin)
          return false if origin == MCP
          return RISK_LADDER.include?(risk_of(tool)) if DYNAMIC_ORIGINS.include?(origin)

          Rubik::Tools::Catalog.coder_tools.include?(name.to_s)
        end

        def self_admits?(tool, origin)
          return true if builtin_origin?(origin)

          RISK_LADDER.include?(risk_of(tool))
        end

        def custom_admits?(tool, origin, write_grant)
          return true if builtin_origin?(origin)

          risk = risk_of(tool)
          return false unless RISK_LADDER.include?(risk)

          risk == :read || write_grant
        end

        # Only the builtin catalog default-allows. Every real, non-builtin
        # origin — known-dynamic, MCP, or a future one — is ladder-gated so a
        # new origin can never bypass the risk rules. nil origin is the
        # registration idiom's implicit builtin.
        def builtin_origin?(origin)
          origin.nil? || origin == :builtin
        end

        def write_grant?(type_def)
          return true if type_def.respond_to?(:enable_write_tools) && type_def.enable_write_tools
          return false unless type_def.respond_to?(:grants)

          Array(type_def.grants).include?("write")
        end

        def admitted_builtin_declarations(type_def)
          root_only = Rubik::Tools::Catalog.orchestrator_only_tools
          names = Rubik::Tools::Catalog.names
          filter = type_def.respond_to?(:tool_filter) ? type_def.tool_filter : nil
          return names.reject { |name| root_only.include?(name) }.filter_map { |name| Rubik::Tools::Catalog[name] } if filter.nil?
          return [] unless filter.arity == 1 || filter.arity.negative?

          names.select { |name| !root_only.include?(name) && filter.call(name) }
               .filter_map { |name| Rubik::Tools::Catalog[name] }
        end

        private_class_method :self_plane?, :research_admits?, :coder_admits?, :self_admits?,
                             :custom_admits?, :builtin_origin?, :write_grant?, :admitted_builtin_declarations
      end
    end
  end
end
