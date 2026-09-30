# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Supervisor'dan çıkarılan araç kapsamlandırıcı (satır sınırı, G-plan
      # hygiene cap'leri): archetype filtresiyle subagent kayıt defterini
      # kurar ve branch-workspace araçlarını yeni buffer'a bağlar.
      module ScopedRegistry
        module_function

        def build(source_registry:, type_def:, child_ctx:, buffer:, parent_buffer:)
          return nil unless source_registry

          new_reg = Rubik::Tools::Registry.new(coeffect_ctx: child_ctx)
          filter = type_def.tool_filter

          source_registry.list.each do |tool|
            next unless filter.nil? || filter.call(tool.name)

            new_reg.register(bind_tool_buffer(tool, buffer, ctx: child_ctx, parent_buffer: parent_buffer))
          end
          new_reg
        end

        # Buffer-bound tools (rebuilt only when a branch buffer splits them
        # off the parent); everything else is context-rebind territory.
        BUFFER_BOUND_TOOLS = ["read_file", "write_file", "replace_file_content", "apply_buffer"].freeze

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

        # ask_question'ın subagent düzlemi: init-0'a yönlendiren asker
        # coeffect'i yalnız child ctx'te sağlanır (supervisor#spawn provide).
        # The rebind MUST precede the buffer guard conceptually: research-type
        # subagents inherit workspace buffers, but ask_question still has to
        # swap to the child ctx — otherwise they would keep the ROOT tool
        # (live shell) and pop a HUMAN dialog from the worker thread.
        def rebind_to_context(tool, ctx)
          return tool unless tool.name == "ask_question" && ctx.respond_to?(:get)

          Rubik::Tools::AskQuestionTool.new(shell: nil, runtime_context: ctx)
        end
      end
    end
  end
end
