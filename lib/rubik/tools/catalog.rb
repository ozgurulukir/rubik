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
        SendMessageTool, DefineSubagentTool, DmesgTool, StorageTool, VakanuvisTool, ShowFileTool, FinishTool
      ].freeze

      # Tools registered outside build_default (dynamically, each with its own
      # ctx inverse) that still carry a canonical DECLARATION.
      DYNAMIC = [SkillTool].freeze

      module_function

      def declarations = BUILTINS.filter_map { |k| k.const_defined?(:DECLARATION, false) ? k::DECLARATION : nil }

      def dynamic_declarations = DYNAMIC.filter_map { |k| k.const_defined?(:DECLARATION, false) ? k::DECLARATION : nil }

      def names = declarations.map(&:name)

      def [](name) = declarations.find { |d| d.name == name.to_s }

      def research_tools = declarations.select { |d| d.archetypes.include?(:research) }.map(&:name).sort.freeze

      def coder_tools = declarations.select { |d| d.archetypes.include?(:coder) }.map(&:name).sort.freeze

      def spawn_tools = declarations.select(&:spawn?).map(&:name).sort.freeze

      def write_grant_tools = declarations.select(&:write_grant?).map(&:name).sort.freeze

      def maestro_blocked_tools = declarations.select(&:maestro_blocked?).map(&:name).sort.freeze

      def maestro_blocked?(name) = maestro_blocked_tools.include?(name.to_s)
    end
  end
end
