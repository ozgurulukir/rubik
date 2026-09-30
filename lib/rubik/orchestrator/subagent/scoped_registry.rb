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

        # Buffer rebinding must preserve runtime-context coeffect reads
        # (rubik://goal/state, rubik://storage, subagent transcripts resolve
        # through ctx): a branch-workspace coder still shares the session's
        # live state.
        def bind_tool_buffer(tool, buffer, ctx: nil, parent_buffer: nil)
          return tool unless buffer && buffer != parent_buffer

          case tool.name
          when "read_file" then Rubik::Tools::ReadFileTool.new(buffer, runtime_context: ctx)
          when "write_file" then Rubik::Tools::WriteFileTool.new(buffer)
          when "replace_file_content" then Rubik::Tools::ReplaceFileContentTool.new(buffer)
          when "apply_buffer" then Rubik::Tools::ApplyBufferTool.new(buffer)
          else tool
          end
        end
      end
    end
  end
end
