# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Gerçek zamanlı LSP tampon-tanı geri beslemesi (Plan 56 D-5) —
    # StepExecutor'dan dürüst çıkarım (satır bütçesi; storage-show-surface
    # planı A'nın :user_output kancası yerine yer açar). Yazma araçlarının
    # ardından tampon LSP'ye senkronize edilir; severity-1 tanılar varsa
    # sonuç çıktısına düzeltme yönlendirmesi eklenir.
    module LspFeedback
      module_function

      WRITER_TOOLS = ["write_file", "replace_file_content"].freeze

      def refresh(deps:, tool_instance:, tool_args:, tool_result:)
        return tool_result unless tool_result.status == :ok
        return tool_result unless WRITER_TOOLS.include?(tool_instance&.name)
        return tool_result unless deps.lsp_manager&.enabled?

        written_file = tool_args["path"] || tool_args[:path]
        return tool_result unless written_file && deps.buffer_manager

        content = deps.buffer_manager.read(written_file)
        synced = deps.lsp_manager.sync_buffer_file(written_file, content)
        return tool_result unless synced && deps.lsp_manager.auto_diagnostics?

        append_diagnostics(deps, written_file, tool_result)
      rescue StandardError => e
        # Loop exposes no logger; the old @loop.logger&.debug raised
        # NoMethodError from inside this rescue itself (fresh-eye
        # review, Plan 87). warn keeps the failure visible on stderr;
        # ANSI stripping keeps LSP-server-controlled messages from
        # injecting terminal escape sequences (red-team E1).
        warn("LSP sync skipped: #{e.message.gsub(/\e\[[0-9;]*[A-Za-z]/, '')}")
        tool_result
      end

      def append_diagnostics(deps, written_file, tool_result)
        sleep 0.05
        diags = deps.lsp_manager.diagnostics_for(written_file)
        errors = diags.select { |d| d["severity"] == 1 }
        return tool_result if errors.empty?

        err_lines = errors.map { |e| "  • Line #{(e.dig('range', 'start', 'line') || 0) + 1}: #{e['message']}" }.join("\n")
        lsp_msg = "\n\n⚠️ [LSP Real-Time Compiler Diagnostics - #{errors.size} error(s)]:\n#{err_lines}\n" \
                  "Please fix these compilation/type errors before proceeding."
        Rubik::Tools::Result.new(
          tool_name: tool_result.tool_name, call_id: tool_result.call_id, status: tool_result.status,
          output: "#{tool_result.output}#{lsp_msg}", duration_ms: tool_result.duration_ms,
          truncated: tool_result.truncated
        )
      end
    end
  end
end
