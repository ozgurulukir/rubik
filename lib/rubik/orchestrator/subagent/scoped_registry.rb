# frozen_string_literal: true

require_relative "../../coeffects"
require_relative "../../tools/catalog"
require_relative "admission_policy"

module Rubik
  module Orchestrator
    module Subagent
      # Supervisor'dan çıkarılan araç kapsamlandırıcı (satır sınırı, G-plan
      # hygiene cap'leri): archetype filtresiyle subagent kayıt defterini
      # kurar ve branch-workspace araçlarını yeni buffer'a bağlar.
      module ScopedRegistry
        module_function

        # K7 (plan 2026-10-04) + context-pruner (2026-10-09): kronikçinin ve
        # budayıcının masaları yalnız kök/maestro düzlemine aittir —
        # subagent kayıt defterlerine ('self' klonu dahil, çünkü onun
        # filtresi yalnız spawn setini dışlar) asla kopyalanmaz. Orkestrasyon
        # belleği tek elde kalır. Derived from the Declarations: a tool with
        # no subagent archetype is orchestrator-plane-only by definition, so
        # the projection cannot drift from the allowlists.
        ROOT_ONLY_TOOLS = Rubik::Tools::Catalog.orchestrator_only_tools.freeze

        def build(source_registry:, type_def:, child_ctx:, buffer:, parent_buffer:)
          return nil unless source_registry
          raise ArgumentError, "ScopedRegistry.build requires a type_def; a nil type_def would grant every tool" unless type_def

          new_reg = Rubik::Tools::Registry.new(coeffect_ctx: child_ctx)
          child_ctx.provide(Rubik::Coeffects::TOOL_REGISTRY, new_reg) if child_ctx.respond_to?(:provide)
          filter = type_def.tool_filter

          source_registry.list.each do |tool|
            next if ROOT_ONLY_TOOLS.include?(tool.name)

            origin = source_registry.origin(tool.name)
            next unless tool_allowed?(filter, tool, origin, type_def)

            new_reg.register(
              bind_tool_buffer(tool, buffer, ctx: child_ctx, parent_buffer: parent_buffer),
              origin: origin || :builtin
            )
          end
          new_reg
        end

        # Executor only: multi-arity filters own their whole decision; the
        # shared arity-1 rule (name filter, then origin/risk) is the
        # AdmissionPolicy's to answer.
        def tool_allowed?(filter, tool, origin, type_def)
          return true if filter.nil?

          if filter.arity != 1
            return filter.call(tool.name, tool, origin) ? true : false
          end

          return false unless filter.call(tool.name)

          AdmissionPolicy.allowed?(tool.name, tool, origin, plane: AdmissionPolicy.plane_for(type_def))
        end

        # Buffer-bound tools (rebuilt only when a branch buffer splits them
        # off the parent); everything else is context-rebind territory.
        # Membership is declared on each tool's Declaration (buffer_bound:)
        # and projected by Catalog; the rebuild itself stays here because
        # branch splitting is an orchestrator concern, not the tool's.
        BUFFER_BOUND_TOOLS = Rubik::Tools::Catalog.buffer_bound_tools.freeze

        # Buffer rebinding must preserve runtime-context coeffect reads
        # (rubik://goal/state, rubik://storage, subagent transcripts resolve
        # through ctx): a branch-workspace coder still shares the session's
        # live state.
        def bind_tool_buffer(tool, buffer, ctx: nil, parent_buffer: nil)
          return rebind_to_context(tool, ctx) unless BUFFER_BOUND_TOOLS.include?(tool.name)
          return tool unless buffer && buffer != parent_buffer

          case tool.name
          when "read_file" then Rubik::Tools::ReadFileTool.new(buffer, runtime_context: ctx)
          when "write_file" then Rubik::Tools::WriteFileTool.new(buffer)
          when "replace_file_content" then Rubik::Tools::ReplaceFileContentTool.new(buffer)
          else Rubik::Tools::ApplyBufferTool.new(buffer)
          end
        end

        # Subagent düzlemine geçen araçlar (ask_question + send_message +
        # orchestration plane): coeffect çözümü yalnız child ctx'te sağlanır
        # (supervisor#spawn/redeploy provide). The rebind MUST precede the
        # buffer guard conceptually: research-type subagents inherit
        # workspace buffers, but ask_question still has to swap to the child
        # ctx — otherwise it would keep the ROOT tool (live shell) and pop a
        # HUMAN dialog from the worker thread; send_message swaps so the
        # subagent-plane message carries its REAL sender id to the maestro;
        # invoke/manage swap so a nested spawn resolves the INSTANCE's task
        # token (issue #125) instead of the root turn's.
        # Each tool owns its rebind_to(ctx) (locality of concern); the
        # registry only decides WHEN. Tools without rebind_to (plugins,
        # dynamic tools registered under the same name) keep their own
        # implementation in every plane.
        def rebind_to_context(tool, ctx)
          return tool unless ctx.respond_to?(:get)

          tool.respond_to?(:rebind_to) ? tool.rebind_to(ctx) : tool
        end
      end
    end
  end
end
