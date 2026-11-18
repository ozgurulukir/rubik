# frozen_string_literal: true

require_relative "../events"
require_relative "../log"
require_relative "../orchestrator/subagent/notices"
require_relative "../prompt/conversation_rows"
require_relative "pending_notice_queue"

module Rubik
  module REPL
    # Issue #469: the notice-routing half of Lifecycle, extracted as a
    # collaborator owning the queue/mutex/token concurrency state
    # (@mcp_notice_tokens, @subagent_event_tokens, @subagent_notices_mutex,
    # @subagent_notices, @pending_notice_queue). Lifecycle keeps the boot
    # phases and delegates; the public Shell surface is unchanged (thin
    # delegating methods).
    #
    # The router holds a reference to its host (Shell or a bare test double)
    # and reads turn/UI state off it via instance_variable_get: @running,
    # @replaying, @autonomous_turn, @active_loop, @output, @terminal_guard,
    # @conversation_history, @config, @event_bus and @runtime_manager are the
    # host's live state and must never be snapshotted.
    #
    # Threading semantics are carried over verbatim: bus dispatch runs on the
    # kworker thread, so handlers touch only the Queue push, the standby
    # Mutex and the guard monitor — never a shell lock. Subscriptions stay
    # inverse-by-construction (unsubscribe registered via ctx.on_dispose in
    # the same breath, AGENTS.md §1A).
    class NoticeRouter
      # Plan 109 Faz B: notice kinds worth interrupting the idle prompt
      # with an autonomous agent-0 turn. Excludes :context_compacted
      # (self-healed, guidance says no action needed) and
      # :auto_apply_failed (informational; the subagent's own next step
      # reports it).
      WAKE_KINDS = [:completed, :budget_exhausted, :error_paused, :message, :question, :task].freeze

      # Single home of the "safe notice print" fallback pattern that used to
      # be reimplemented per call site (lifecycle boot notices, MCP boot
      # notices, subagent routing, flush; turn_recorder keeps its own until
      # it needs the newline conventions changed): print through the guard
      # when one exists, else fall back to the host output stream.
      def self.print_safe_notice_line(terminal_guard, output, line)
        if terminal_guard
          terminal_guard.print_safe_notice(line)
        else
          output&.puts line
        end
      end

      # Test seam and lazy storage: the user-channel standby buffer and its
      # mutex (the router owns them; tests pin flush/routing semantics
      # against the router). Lazily created so routing buffers safely even
      # before wire_subagent_events! runs (bare test-double harness mold).
      def subagent_notices
        @subagent_notices ||= []
      end

      def subagent_notices_mutex
        @subagent_notices_mutex ||= Mutex.new
      end

      def initialize(shell)
        @shell = shell
      end

      # Async MCP boot progress notices (mcp-async-boot D8): subscribe BEFORE
      # the boot triggers so no event is missed, with the unsubscribe inverse
      # registered in the same breath (wire_subagent_events! pattern). Async
      # mode only — a synchronous boot finishes before the first prompt, so
      # its failures already surfaced on stderr.
      def wire_mcp_boot_notices!(async:)
        return unless async && event_bus
        return if @mcp_notice_tokens # idempotent re-wire

        ctx = runtime_manager&.context
        return unless ctx.respond_to?(:on_dispose)

        @mcp_notice_tokens = [
          [:mcp_server_loaded, event_bus.subscribe(:mcp_server_loaded) { |payload| print_mcp_boot_notice(:loaded, payload) }],
          [:mcp_server_failed, event_bus.subscribe(:mcp_server_failed) { |payload| print_mcp_boot_notice(:failed, payload) }]
        ]
        ctx.on_dispose do
          @mcp_notice_tokens&.each { |(event, token)| event_bus.unsubscribe(event, token) }
          @mcp_notice_tokens = nil
        end
      end

      # Same kworker-thread contract as handle_subagent_event: no shell locks,
      # drop silently when the UI is not up yet (an instant boot failure is
      # still on stderr and in dmesg). Pure display line — never enters the
      # conversation history and never wakes an idle turn.
      def print_mcp_boot_notice(state, payload)
        return unless shell_state(:running) && shell_state(:output)
        return unless payload.is_a?(Hash)

        name = payload[:server]
        line = if state == :loaded
                 "mcp: server '#{name}' ready (#{payload[:tools] || 0} tools)"
               else
                 "mcp: server '#{name}' failed (#{payload[:error]})"
               end
        shell_state(:terminal_guard)&.print_safe_notice(line)
      end

      def wire_subagent_events!
        return unless event_bus
        return if @subagent_event_tokens # idempotent re-wire (RenderService precedent)

        # Inverse-by-construction: subscribe only where the unsubscribe
        # inverse can be registered in the same breath (AGENTS.md §1A).
        ctx = runtime_manager&.context
        return unless ctx.respond_to?(:on_dispose)

        @subagent_notices_mutex = Mutex.new
        @subagent_notices = []
        # Plan 109: the idle-turn wake flag, eagerly initialized BEFORE any
        # subscription exists so handlers never race its construction.
        @pending_notice_queue = PendingNoticeQueue.new
        tokens = Rubik::Orchestrator::Subagent::Notices::EVENTS.keys.map do |event|
          [event, event_bus.subscribe(event) { |payload| handle_subagent_event(event, payload) }]
        end
        tokens << [Rubik::Events::UNIT_STATE_CHANGED, event_bus.subscribe(Rubik::Events::UNIT_STATE_CHANGED) { |payload| handle_unit_event(payload) }]
        tokens << [Rubik::Events::SUBAGENT_MESSAGE_TO_PARENT, event_bus.subscribe(Rubik::Events::SUBAGENT_MESSAGE_TO_PARENT) { |payload| handle_parent_message(payload) }]
        @subagent_event_tokens = tokens
        ctx.on_dispose do
          @subagent_event_tokens&.each { |(event, token)| event_bus.unsubscribe(event, token) }
          @subagent_event_tokens = nil
        end
      end

      # ONE routing seam for subagent notices (Candidate 02, unified for
      # Plan 109): bus event -> normalized notice -> channel-split
      # delivery. Called on the kworker thread (bus dispatch is
      # synchronous): Queue pushes, the standby Mutex, and the guard
      # monitor only — no shell locks. Model channel (structured hash)
      # enters the active loop queue and is rendered to XML at drain
      # time; user channel (terminal line) is buffered to stdout while a
      # loop is active and flushed at turn end. Between turns the notice
      # is injected into the conversation history, printed, and — when
      # wake-worthy — queued to owe agent-0 an autonomous notice turn.
      def handle_subagent_event(event_name, payload)
        return unless shell_state(:running) && shell_state(:output) && !shell_state(:replaying)

        notice = Rubik::Orchestrator::Subagent::Notices.normalize(event_name, payload)
        route_subagent_notice(notice) if notice
      end

      def handle_unit_event(payload)
        return unless shell_state(:running) && shell_state(:output) && !shell_state(:replaying)
        return unless payload.is_a?(Hash)

        type = payload[:type]&.to_sym
        return unless [:process, :task].include?(type)

        to_state = payload[:to_state]&.to_sym
        return unless [:completed, :failed].include?(to_state)

        route_subagent_notice({ kind: :task, id: payload[:unit_id], role: "Background Task", state: to_state.to_s, reason: payload[:reason] })
      end

      def handle_parent_message(payload)
        return unless shell_state(:running) && shell_state(:output) && !shell_state(:replaying)
        return unless payload.is_a?(Hash)

        route_subagent_notice({ kind: :message, id: payload[:sender_id] || "subagent",
                                role: "Subagent", state: "message", reason: payload[:message].to_s })
      end

      def route_subagent_notice(notice)
        line = Rubik::Orchestrator::Subagent::Notices.user_line(notice)
        if shell_state(:active_loop)
          active_loop = shell_state(:active_loop)
          active_loop.enqueue_subagent_notice(notice) if active_loop.respond_to?(:enqueue_subagent_notice)
          subagent_notices_mutex.synchronize { subagent_notices << line }
        else
          inject_subagent_notice_into_conversation_history!(notice)
          output = shell_state(:output)
          if shell_state(:terminal_guard)
            shell_state(:terminal_guard).print_safe_notice(line)
          else
            output.puts "\n#{line}"
          end
          # Wakeloop fix 2026-10-09: an event landing inside an AUTONOMOUS
          # turn's idle-path windows (before @active_loop is set, or in the
          # ensure tail after it is cleared) must not arm a follow-up wake —
          # that is the probabilistic residue of the chained-auto-turn bug.
          # History injection and the printed line above still happen (no
          # loss); only the synthetic Enter is withheld. A fresh event at a
          # genuinely idle prompt (@autonomous_turn false) wakes as designed.
          request_reactive_wakeup!(notice) unless shell_state(:autonomous_turn)
        end
      end

      # Plan 109 Faz B: the reactive wake composition — vocabulary policy
      # (WAKE_KINDS), kill-switch (subagents.reactive_wakeup config),
      # state (PendingNoticeQueue), mechanism (TerminalGuard#safe_wakeup!).
      # Every wake-worthy enqueue attempts the kick (no empty->non-empty
      # coalescing): a kick refused earlier (user typing / paste
      # collection) must retry on the next event, or the wake would wait
      # for a manual Enter. TerminalGuard re-verifies emptiness under its
      # monitor, so a typing user is never disturbed, and a surplus
      # injected Enter degrades to the :empty noop. Runs on the kworker
      # thread: queue push and the guard monitor only.
      def request_reactive_wakeup!(notice)
        return unless reactive_wakeup_enabled?
        return unless notice.is_a?(Hash) && WAKE_KINDS.include?(notice[:kind])

        pending_notice_queue.enqueue(notice)
        shell_state(:terminal_guard)&.safe_wakeup!
      end

      def reactive_wakeup_enabled?
        Rubik::Storage::Layout.config_get(shell_state(:config), "subagents.reactive_wakeup", true) != false
      end

      # Eager init happens in wire_subagent_events! (before any
      # subscription exists); the lazy fallback keeps bare Lifecycle test
      # doubles working (SubagentNoticeInbox mold).
      def pending_notice_queue
        @pending_notice_queue ||= PendingNoticeQueue.new
      end

      def pending_wake_notices?
        pending_notice_queue.any?
      end

      def drain_pending_wake_notices!
        pending_notice_queue.drain_all
      end

      # Staleness rule: any real turn's context already includes the
      # idle-injected notices in the conversation history — a surviving
      # pending wake would turn the next stray Enter into a redundant
      # notice turn.
      def clear_pending_wake_notices!
        pending_notice_queue.clear!
      end

      def inject_subagent_notice_into_conversation_history!(notice)
        xml_payload = Rubik::Orchestrator::Subagent::Notices.history_block([notice])
        # The bus thread injects while the turn thread may replace the whole
        # history array in trim_conversation_window!. Share the standby mutex
        # with that mutation so a notice is never written to a stale array
        # (issue #557).
        subagent_notices_mutex.synchronize do
          history = shell_state(:conversation_history)
          unless history
            history = []
            @shell.instance_variable_set(:@conversation_history, history)
          end
          Rubik::Prompt::ConversationRows.append_notice!(history, xml_payload)
        end
      end

      def flush_subagent_notices!
        output = shell_state(:output)
        return unless output

        notices = subagent_notices_mutex.synchronize do
          list = subagent_notices.dup
          subagent_notices.clear
          list
        end
        return if notices.empty?

        if shell_state(:terminal_guard)
          notices.each { |m| shell_state(:terminal_guard).print_safe_notice(m) }
        else
          output.puts ""
          notices.each { |m| output.puts m }
        end
      end

      # Session review B3 (turn-loss fix): Loop's drain runs at the TOP of each
      # step, so notices landing during the final step stranded in the loop
      # inbox at turn end — the user channel flushed a line, but the model
      # channel never entered history and no wake was owed (Plan 109's
      # documented "late-notice asymmetry" accepted the loss; a live session
      # showed it costs a whole turn). Called from execute_free_text's ensure
      # AFTER the active loop is cleared: the notices are injected into
      # the conversation history (visible to the next turn) and wake-worthy
      # kinds arm the reactive wake, exactly like the idle-path branch of
      # route_subagent_notice. Runs on the turn thread. Per-notice rescue is
      # the ensure block's own contract ("cleanup must never mask the
      # in-flight exception") — and a raising notice must not strand its
      # queue-mates that drain_all already popped.
      #
      # arm_wake: false keeps the model-channel delivery but does NOT fire a
      # synthetic Enter (wakeloop fix 2026-10-09): an INTERRUPTED turn and an
      # AUTONOMOUS notice turn settle instead of re-arming — otherwise every
      # stranded notice chains another auto-turn (the prompt never returns)
      # and the cycle survives Ctrl+C.
      def deliver_stranded_loop_notices!(loop_instance, arm_wake: true)
        return unless loop_instance.respond_to?(:subagent_notice_inbox)

        loop_instance.subagent_notice_inbox.drain_all.each do |notice|
          inject_subagent_notice_into_conversation_history!(notice)
          request_reactive_wakeup!(notice) if arm_wake
        rescue StandardError => e
          # Load-bearing visibility (wakeloop fix 2026-10-09): this delivery
          # is the fix's "no loss" guarantee, so a dropped notice may not
          # vanish behind the ENV-gated debug_warn. Unconditional, non-raising.
          Rubik::Log.warn(:repl, "stranded notice delivery failed (#{notice[:kind].inspect}): " \
                                 "#{e.class}: #{e.message}")
        end
      end

      private

      # Live host state — never snapshotted; instance_variable_get keeps
      # bare Lifecycle test doubles (plain ivars, no readers) working.
      def shell_state(name)
        @shell.instance_variable_get(:"@#{name}")
      end

      def event_bus
        shell_state(:event_bus)
      end

      def runtime_manager
        shell_state(:runtime_manager)
      end
    end
  end
end
