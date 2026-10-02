# frozen_string_literal: true

module Rubik
  module Prompt
    # Frozen-in view of everything the prompt renderer needs (architecture
    # review 2026-10-01, candidate 2). Unlike Tools::Services there is NO
    # fresh tier and NO coeffect lookup here: the prompt layer never
    # constructs services (a Guard/Sandbox built here would be policy the
    # caller never granted) and never resolves coeffects — the orchestrator
    # resolves, the prompt renders. Unsatisfied slots degrade to empty
    # sections, exactly matching the builder's historical nil-tolerant
    # rendering.
    #
    # Owns: the slot list (the Struct members are the SSOT) and its frozen
    # snapshot semantics.
    # Leaves: where values come from — the composition root builds the
    # view (from_shell / explicit kwargs); coeffect resolution (skills
    # index, type registry) stays in the orchestrator.
    Services = Struct.new(
      :config, :commands, :buffer_manager, :snapshot_store, :context_index,
      :lsp_manager, :skills_index, :type_registry, :context_limit,
      :max_output_tokens, :root_dir, :extra_context,
      keyword_init: true
    ) do
      def initialize(config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil,
                     lsp_manager: nil, skills_index: nil, type_registry: nil, context_limit: nil,
                     max_output_tokens: nil, root_dir: Dir.pwd, extra_context: "")
        super
        freeze
      end

      # Reader-only shell view: a public reader contributes its value, a
      # reader-less duck type contributes nothing (graceful degradation,
      # never a raise). Explicit non-nil overrides beat shell readers,
      # preserving the builder's historical kwarg-over-shell precedence
      # (test_build_system_prompt_config_takes_precedence_over_shell_config).
      # root_dir/context_limit/max_output_tokens/skills_index/extra_context
      # are per-run values, not shell state — they arrive via overrides.
      def self.from_shell(shell, **overrides)
        supervisor = reader(shell, :subagent_supervisor)
        base = {
          config: reader(shell, :config),
          commands: reader(shell, :commands),
          buffer_manager: reader(shell, :buffer_manager),
          snapshot_store: reader(shell, :snapshot_store),
          context_index: reader(shell, :context_index),
          # Phase-2 behavior shim: the builder's historical ivar reach-ins,
          # moved verbatim so reader-less shells keep rendering; deleted in
          # Phase 3 (public readers become the only shell path).
          lsp_manager: reader(shell, :lsp_manager) || shell&.instance_variable_get(:@lsp_manager),
          type_registry: (supervisor || shell&.instance_variable_get(:@subagent_supervisor))&.type_registry
        }
        new(**base, **overrides.compact)
      end

      def self.reader(shell, name)
        shell.respond_to?(name) ? shell.public_send(name) : nil
      end
    end
  end
end
