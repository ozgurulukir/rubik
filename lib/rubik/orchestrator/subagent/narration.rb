# frozen_string_literal: true

require_relative "notices"

module Rubik
  module Orchestrator
    module Subagent
      # THE render seam: (lifecycle state, facts) -> text, one direction,
      # no reverse writes. Pure — no locks, no IO, no instance state; the
      # only require is the notices vocabulary leaf. Every state->text
      # spelling for an Instance's own lifecycle (state_note, the
      # manage_subagents status/wait guidance) and the manage_subagents
      # action vocabulary (schema enum, dispatch keys, help list, error
      # text) projects from here, so the drift between them is
      # unexpressable: the session-review bug class (B3 stale placeholder,
      # B4 grants-blind halt wording) existed because narration was
      # hand-STORED beside state instead of derived from it.
      module Narration
        module_function

        # --- instance-state narration (the only home of state->text) ---

        # The pause/halt story for a lifecycle state, computed on demand.
        # state is an Instance::TRANSITIONS key; silent states (live or
        # settled runs) yield nil — :completed narrates via its real
        # :result, plain :failed via :last_error, so nothing is invented.
        # paused_after_s is the recorded wait fact (Instance#pause_facts)
        # feeding the halt wording's "within Ns" clause.
        def state_note(state, grants_received: 0, max_steps: nil, last_error: nil, paused_after_s: nil)
          case state.to_sym
          when :waiting_budget
            "Paused awaiting budget expansion from the maestro."
          when :budget_exhausted
            if grants_received.positive?
              # B4: after a consumed grant the halt must say no FURTHER
              # expansion arrived — "not received" read as a lost grant.
              "#{Notices.budget_exhausted_line(max_steps)} No further budget expansion arrived " \
                "within #{paused_after_s ? "#{paused_after_s}s" : 'the wait timeout'} " \
                "(#{grants_received} grant(s) were received and consumed earlier)."
            else
              "#{Notices.budget_exhausted_line(max_steps)} Budget expansion was not received from the maestro."
            end
          when :paused_error
            "Paused awaiting error recovery: #{last_error}"
          when :waiting_input
            "Asked the maestro a clarifying question; blocked awaiting the answer."
          when :failed
            "Subagent halted after #{paused_after_s}s in paused_error state: #{last_error}" if paused_after_s
          end
        end

        # manage_subagents status/wait channel: blocked states get the exact
        # recovery action, a mid-flight worker gets the poll discipline. All
        # other states yield nil (no story).
        def guidance(state, id:, max_steps:, step: nil, uptime: nil)
          case state.to_sym
          when :waiting_input
            "Subagent asked a question and is BLOCKED awaiting your answer. Reply via send_message(recipient: '#{id}', message: '<your answer>')."
          when :waiting_budget
            Notices.budget_paused_line(id, max_steps)
          when :budget_exhausted
            Notices.budget_exhausted_line(max_steps)
          when :paused_error
            "Subagent paused on provider/network error. Call manage_subagents(action: 'resume', conversation_id: '#{id}') to retry."
          when :running
            # The poll-discipline story needs the live facts; callers without
            # them (wait rows, plain state dispatch) get nil = no story —
            # this guidance channel was budget-states-only before the seam.
            if step && uptime
              "Subagent is actively working (step #{step}/#{max_steps}, #{uptime.round(1)}s uptime). " \
                "DO NOT poll 'status' in a loop! Call #{Notices.wait_any_hint} to block until completion, " \
                "or simply stop calling tools to receive reactive wakeup."
            end
          end
        end

        # Wait-return narration (issue #126): WHY the wait returned, as the next
        # actionable fact; nil for a settled wait (no story to tell).
        WAIT_REASON_HINTS = {
          deadline: "Deadline reached while subagent(s) remain ACTIVE — they keep running; wait again with a longer timeout or conclude your turn.",
          paused: "Subagent(s) are paused and need an action (extend_budget / resume / answer their question) before the chain continues.",
          queued: "Only dependency-queued work remains — it launches automatically once its predecessors settle; no action needed.",
          unknown: "No such subagent id(s) — check the roster with manage_subagents(action: 'list')."
        }.freeze

        def wait_reason_hint(reason)
          WAIT_REASON_HINTS[reason.to_sym]
        end

        # The nil-provider fast path's terminal stub (a legitimate outcome:
        # no provider, no story beyond the echo of the task itself).
        def completed_stub_line(id, role, prompt)
          "Subagent [#{id}] (#{role}) completed task successfully: #{prompt.slice(0, 80)}"
        end

        # --- manage_subagents action vocabulary (single declaration) ---

        # One canonical row per action; model-facing aliases ride along.
        # The schema enum, the dispatch canonicalization, the description's
        # action list, and the unknown-action error are ALL projections of
        # this table — adding an action means adding a row, nothing else.
        Action = Struct.new(:canonical, :aliases, :param, keyword_init: true)

        ACTION_SPECS = [
          Action.new(canonical: "list", aliases: []),
          Action.new(canonical: "status", aliases: [], param: "conversation_id"),
          Action.new(canonical: "wait", aliases: [], param: "conversation_ids"),
          Action.new(canonical: "transcript", aliases: [], param: "conversation_id"),
          Action.new(canonical: "result", aliases: [], param: "conversation_id"),
          Action.new(canonical: "extend_budget", aliases: ["grant_steps", "extend"], param: "conversation_id"),
          Action.new(canonical: "resume", aliases: ["retry"], param: "conversation_id"),
          Action.new(canonical: "redeploy", aliases: [], param: "conversation_id"),
          Action.new(canonical: "reap", aliases: ["clean"]),
          Action.new(canonical: "kill", aliases: [], param: "conversation_ids"),
          Action.new(canonical: "kill_all", aliases: ["killall"])
        ].freeze

        CANONICAL_NAMES = ACTION_SPECS.map(&:canonical).freeze

        # Model-facing vocabulary: canonical names plus their aliases (the
        # schema enum previously drifted from dispatch by missing "killall").
        SCHEMA_ACTIONS = ACTION_SPECS.flat_map { |spec| [spec.canonical, *spec.aliases] }.freeze

        CANONICAL_LOOKUP = ACTION_SPECS.flat_map { |spec| [spec.canonical, *spec.aliases].map { |token| [token, spec.canonical] } }.to_h.freeze

        # Alias-resolving dispatch key; nil = unknown action.
        def canonical_action(token)
          token && CANONICAL_LOOKUP[token.to_s.downcase.strip]
        end

        # Rendered canonical list for the tool description (order-stable, so
        # TOOLS.md generation stays byte-identical).
        def quoted_canonical_list
          CANONICAL_NAMES.map { |name| "'#{name}'" }.join(", ")
        end
      end
    end
  end
end
