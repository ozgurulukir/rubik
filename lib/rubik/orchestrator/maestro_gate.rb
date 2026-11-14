# frozen_string_literal: true

require_relative "../tools/catalog"
require_relative "tool_history"
require_relative "../storage/layout"

module Rubik
  module Orchestrator
    # Maestro kapısı (kullanıcı kararı 2026-10-01, opencode-personal
    # bulgusu): maestro HER modda saf orkestratördür — kök ajanın doğrudan
    # yürütme araç çağrıları ÇALIŞTIRILMADAN reddedilir ve subagent'a
    # yönlendirilir. Yalnız StepExecutor (Loop'un kök yolu) bu modülü
    # içerir: subagent'lar StepRunner'ın kendi dispatch'inden gider, buraya
    # asla uğramaz. Config subagents.maestro_gate ile aç/kapa (default
    # açık); kapı canlı okur ama ajan config'i değiştiremez (workspace.rb
    # Paket D: subagents.* operatör-only) — self-unlock yolu kapalı.
    module MaestroGate
      # Kapı sınıfı Tools::Catalog'un maestro_blocked projeksiyonundan türetil
      # (tek kaynak: her aracın DECLARATION'ı); her :write/:execute araç beyanı
      # açıkça vermek zorundadır — yeni bir mutasyon aracı sessizce kapıdan
      # kaçamaz (no-silent-escape invariant'i,
      # test_tool_declaration_catalog.rb). Yalnız YÜRÜTME araçları kapılı:
      # salt-okunur keşif, storage, ask_question ve finish serbest.
      # manage_task action-bazlıdır: start = run_command eşdeğeri arka plan
      # shell'i; list/status/logs/send_input/kill orkestrasyon komşusu olarak
      # serbest kalır.
      def maestro_gate_blocks?(canonical_name, tool_args = {})
        return false unless Rubik::Tools::Catalog.maestro_blocked?(canonical_name)
        return false if canonical_name == "manage_task" &&
                        !["start"].include?((tool_args["action"] || tool_args[:action]).to_s.downcase.strip)

        # Kapıyı çalışma anında config'den oku (!config set ile operatör
        # aç/kapa mümkün). config_get (Storage::Layout) gerçek Config'in
        # dotted fetch'ini ve düz Hash'in nested (dig) şeklini tek evde
        # çözer.
        cfg = @deps.shell&.config
        raw = Rubik::Storage::Layout.config_get(cfg, "subagents.maestro_gate", nil)
        raw != false
      end

      # Red = yönlendirme: mesaj ne olduğunu, neden ve NASIL düzgün
      # yapılacağını söyler (empathetic error, AGENTS.md §5). invalid-tool
      # sayacına dokunmaz — bu çağrı geçersiz değil, devredilmiş bir istek.
      def maestro_refusal(canonical_name, tool_name, call_id)
        result = Rubik::Tools::Result.new(
          tool_name: tool_name,
          call_id: call_id,
          status: :error,
          error: "Maestro gate: '#{canonical_name}' is delegated to subagents.",
          output: "Maestro doctrine: the maestro is a pure orchestrator and never executes '#{canonical_name}' itself — " \
                  "execution work belongs to subagents in every mode. This call was NOT executed. Dispatch a subagent instead: " \
                  "invoke_subagent with type_name 'coder' (file edits, tests, commands, background processes) or 'research' " \
                  "(read-only exploration), then collect results via manage_subagents (action: 'wait' or 'transcript') and " \
                  "steer with send_message, or hand follow-ups to a finished subagent with manage_subagents (action: 'redeploy').",
          duration_ms: 0.0
        )
        Rubik::Orchestrator::ToolHistory.write(@deps.history, tool_call_id: call_id, tool_name: tool_name,
                                                              status: :error, duration_ms: 0.0, content: result.to_xml)
        @deps.activity.record(canonical_name, {}, :error) if @deps.respond_to?(:activity) && @deps.activity
      end
    end
  end
end
