# frozen_string_literal: true

module Rubik
  module Orchestrator
    # THE canonical tool-result history row — the dictionary single source
    # of truth (agent-turn-executor plan, Phase 1). Every channel's writer
    # (StepExecutor registered/invalid, MaestroGate refusal, subagent
    # dispatch) constructs its row through ToolHistory.write, so key drift
    # between channels is structurally impossible.
    #
    # Provider-consumption evidence (formatter.rb et al.):
    # - tool_call_id — required by OpenAI native function calling
    #   (formatter.rb, extract_call_id) and Anthropic tool_use pairing;
    #   also read by TokenEstimator.
    # - tool_name — OpenAI non-native and Ollama prefixed-user-message
    #   paths, TokenEstimator, ContextCompactor skill-tool filter,
    #   TranscriptFormatter.
    # - status / duration_ms — read by NO wire-side consumer; observability
    #   only (tests, REPL events, stored transcripts). Formatters build
    #   fresh hashes and ignore unknown keys, so carrying them everywhere is
    #   wire-safe for every provider path.
    # - content — an opaque String per channel (main path: Result#to_xml;
    #   subagent: truncated plain output). The dictionary unifies the row
    #   SHAPE, not the content encoding.
    # - exit_code / metadata (issue #127) — the structured command outcome:
    #   machine-readable status without parsing display text. Also read by no
    #   wire-side consumer (same observability-only contract as status), so
    #   every channel writing nil/{} keeps the shape stable.
    module ToolHistory
      ROW_KEYS = [:role, :tool_call_id, :tool_name, :status, :duration_ms, :content, :exit_code, :metadata].freeze

      module_function

      # Appends exactly one canonical row to +history+ and returns it.
      def write(history, tool_call_id:, tool_name:, status:, duration_ms:, content:, exit_code: nil, metadata: nil)
        row = { role: "tool", tool_call_id: tool_call_id, tool_name: tool_name,
                status: status, duration_ms: duration_ms, content: content,
                exit_code: exit_code, metadata: metadata || {} }
        history << row
        row
      end
    end
  end
end
