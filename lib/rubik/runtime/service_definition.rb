# frozen_string_literal: true

module Rubik
  module Runtime
    # Declarative vocabulary entry for one composed service (architecture-
    # review Candidate 05). A ServiceDefinition is pure data: it names a
    # service, binds it to the coeffect key it is published under, and flags
    # how the composition root should carry it (Parts member, shell ivar,
    # shell reader, wire-time provide). It never builds anything and never
    # touches a context.
    #
    #   owns   : the field semantics of a service declaration
    #   leaves : entry ORDER and the entries themselves (REPL::ServiceCatalog
    #            — the composition root's table); key STRINGS and legacy
    #            aliases (Rubik::Coeffects SSOT); how tool-layer defaults
    #            resolve (Tools::Services)
    #
    # Kinship: ComponentFiber declares `inject:` coeffect contracts for
    # runtime consumers; ServiceDefinition declares the provider-side mirror
    # for the composition root. TypeDefinition
    # (orchestrator/subagent/type_registry.rb) is the structural precedent.
    #
    # Builders receive the catalog Scope (root_dir, home_dir, and hash access
    # to already-constructed entries: scope[:guard]). Referencing an entry
    # ordered later raises immediately — the construction-order invariant
    # (guard before its consumers; runtime_manager before task_manager,
    # skills and mcp; buffer before the subagent supervisor) is structural,
    # not editorial.
    ServiceDefinition = Struct.new(
      :name,          # Symbol — Parts member, Shell ivar, build_default override slot
      :provide,       # coeffect key published at wire time (Coeffects::* constant where
      # one exists), nil when never provided (cache_store, recorder, ...)
      :provide_from,  # :ivar (default) | :parts | :self — where wire reads the value
      :builder,       # ->(scope) { instance }; nil only for the shell pseudo-entry
      :input,         # true for config-derived wiring values (extra_roots, ...): Parts
      # member only — no ivar, no reader, no provide
      :parts_member,  # false ONLY for the shell pseudo-entry (provided, never built)
      :optional,      # true -> inject uses a respond_to? nil-guard (older parts fixtures)
      :assign_ivar,   # false -> Parts member + provide only, no Shell ivar (plugin_storage)
      :reader,        # false -> no derived Shell attr_reader (plugin_manager today)
      :after_build,   # ->(scope) { } runs right after this entry's construction
      :after_inject,  # ->(values, parts, injected_buffer) { } runs after ALL ivars are set
      keyword_init: true
    ) do
      def initialize(**kwargs)
        super(parts_member: true, provide_from: :ivar, **kwargs)
      end

      def provided? = !provide.nil?
      def injectable? = !input && assign_ivar != false && parts_member != false
      def expose_reader? = injectable? && reader != false
    end
  end
end
