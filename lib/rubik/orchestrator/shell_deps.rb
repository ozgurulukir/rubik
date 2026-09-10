# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Narrow façade over Loop for the extracted collaborators (Plan 87 E-1,
    # carrying Plan 86 D-5). Collaborators reach loop-held state only through
    # this object instead of poking `@loop` directly (Law of Demeter).
    #
    # Design notes:
    # - Reads are forwarded, not re-declared: capability queries such as
    #   `deps.respond_to?(:safe_config)` must keep the exact semantics the
    #   collaborators rely on with minimal test doubles (some doubles do not
    #   define every accessor), so the surface is forwarded through
    #   respond_to_missing?/method_missing guarded by the declared SURFACE.
    # - Writes are an explicit command surface: history rebinding and the
    #   counter/flag mutations become named methods instead of leaking
    #   Loop's attr_accessors.
    # - `loop_instance` exists for the turn-result contract only: result
    #   hashes carry the loop object itself so the shell can drive
    #   `continue_loop` afterwards.
    class ShellDeps
      # Read surface: symbols collaborators consume from Loop at call time.
      SURFACE = [
        :history, :activity, :config, :shell, :buffer_manager, :lsp_manager,
        :tool_registry, :provider, :budget_manager, :on_step,
        :step_count, :max_steps, :context_limit, :max_output_tokens,
        :total_tokens, :invalid_tool_count, :last_turn_streamed,
        :context_warning_emitted, :safe_config
      ].freeze

      # Collaborator constructor shim: accepts an already-built façade or a
      # bare loop (test doubles) and wraps the latter.
      def self.wrap(loop_or_deps)
        loop_or_deps.is_a?(ShellDeps) ? loop_or_deps : ShellDeps.new(loop_or_deps)
      end

      def initialize(loop)
        @loop = loop
      end

      # Turn-result contract (see class comment): the underlying Loop object.
      def loop_instance
        @loop
      end

      # ── Command surface ───────────────────────────────────────────────
      # compact_history is pure and returns a new array, so the history
      # reference itself must be rebound on Loop (BudgetManager compaction).
      def replace_history!(new_history)
        @loop.history = new_history
      end

      def reset_invalid_tools!
        @loop.invalid_tool_count = 0
      end

      def record_invalid_tool!
        @loop.invalid_tool_count += 1
      end

      def mark_last_turn_streamed!(streamed)
        @loop.last_turn_streamed = streamed
      end

      def flag_context_warning!
        @loop.context_warning_emitted = true
      end

      def emergency_compact_and_notify!(reason)
        @loop.emergency_compact_and_notify!(reason)
      end

      def respond_to_missing?(name, include_private = false)
        (SURFACE.include?(name) && @loop.respond_to?(name, include_private)) || super
      end

      def method_missing(name, *, &)
        return @loop.public_send(name, *, &) if SURFACE.include?(name) && @loop.respond_to?(name)

        super
      end
    end
  end
end
