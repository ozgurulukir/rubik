# frozen_string_literal: true

require_relative "declaration"
require_relative "builtins"

module Rubik
  module Tools
    # Frozen load-time projection over the builtin DECLARATIONs: the single
    # place archetype allowlists, the spawn set, the custom-type write gate,
    # the maestro gate and doc tables derive from (architecture review
    # 2026-10-01, candidate 1). Membership pins "a class that exists is
    # registered, and vice versa"; ORDER mirrors Registry.build_default
    # registration order exactly (both directions invariant-tested).
    #
    # This is a load-time constant module — the same class of thing as
    # Rubik::Coeffects, not a registry. Dynamically registered tools (MCP,
    # plugins, synthesis) cannot join it; they use Registry#register's
    # per-instance path unchanged.
    module Catalog
      BUILTINS = [
        ReadFileTool, ReplaceFileContentTool, WriteFileTool, ListFilesTool, GrepSearchTool,
        SearchSymbolsTool, GetOutlineTool, FindReferencesTool, GetSymbolTool,
        LSPDiagnosticsTool, LSPHoverTool, LSPDefinitionTool, RunTestsTool, RunCommandTool,
        ManageTaskTool, ExecReplCommandTool, SynthesizeCommandTool, SynthesizeToolTool,
        UnsynthesizeTool, InspectRuntimeTool, ProvideServiceTool, RepairRuntimeTool,
        ApplyBufferTool, AskQuestionTool, InvokeSubagentTool, ManageSubagentsTool,
        SendMessageTool, DefineSubagentTool, DmesgTool, StorageTool, VakanuvisTool, PruneContextTool, ShowFileTool, FinishTool
      ].freeze

      # Tools registered outside build_default (dynamically, each with its own
      # ctx inverse) that still carry a canonical DECLARATION.
      DYNAMIC = [SkillTool].freeze

      # PERF: Pre-compute and freeze load-time projections to avoid re-filtering,
      # re-sorting, array allocations, and linear scans on hot query paths.
      DECLARATIONS = BUILTINS.filter_map { |k| k.const_defined?(:DECLARATION, false) ? k::DECLARATION : nil }.freeze
      DYNAMIC_DECLARATIONS = DYNAMIC.filter_map { |k| k.const_defined?(:DECLARATION, false) ? k::DECLARATION : nil }.freeze
      NAMES = DECLARATIONS.map(&:name).freeze
      DECLARATIONS_BY_NAME = DECLARATIONS.to_h { |d| [d.name, d] }.freeze
      RESEARCH_TOOLS = DECLARATIONS.select { |d| d.archetypes.include?(:research) }.map(&:name).sort.freeze
      CODER_TOOLS = DECLARATIONS.select { |d| d.archetypes.include?(:coder) }.map(&:name).sort.freeze
      SPAWN_TOOLS = DECLARATIONS.select(&:spawn?).map(&:name).sort.freeze
      WRITE_GRANT_TOOLS = DECLARATIONS.select(&:write_grant?).map(&:name).sort.freeze
      MAESTRO_BLOCKED_TOOLS = DECLARATIONS.select(&:maestro_blocked?).map(&:name).sort.freeze
      MAESTRO_BLOCKED_SET = MAESTRO_BLOCKED_TOOLS.to_set.freeze

      module_function

      def declarations = DECLARATIONS

      def dynamic_declarations = DYNAMIC_DECLARATIONS

      def names = NAMES

      def [](name) = DECLARATIONS_BY_NAME[name.to_s]

      def research_tools = RESEARCH_TOOLS

      def coder_tools = CODER_TOOLS

      def spawn_tools = SPAWN_TOOLS

      def write_grant_tools = WRITE_GRANT_TOOLS

      def maestro_blocked_tools = MAESTRO_BLOCKED_TOOLS

      def maestro_blocked?(name) = MAESTRO_BLOCKED_SET.include?(name.to_s)
    end
  end
end
