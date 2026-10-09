# frozen_string_literal: true

require_relative "service_catalog"
require_relative "../session/replayer"

module Rubik
  module REPL
    # Per-dispatch, closed view of the Shell for bang-command handlers —
    # the §7.1 ShellDeps pattern applied to the command axis. Built inside
    # InputExecution#execute_command, AFTER with_output has swapped the
    # capture TeeIO in, so ctx.out is exactly the stream a handler should
    # print to on both the human and the exec_repl_command path (recorder
    # capture and LLM-history truncation keep working unchanged).
    #
    # Closed surface (frozen by test_command_context):
    #   · out / output : the active (capture-aware) IO. `output` exists so
    #     the UI collaborators (Panel / DiffViewer / Approvals) can take ctx
    #     where they previously took the shell — structural duck, UI files
    #     untouched.
    #   · services     : derived from ServiceCatalog.reader_names — the SSOT.
    #     Adding a catalog service extends ctx automatically; optional
    #     services read as nil (no respond_to? probing).
    #   · rebindable   : conversation_history / active_loop (get + set) and
    #     conversation_route_stamp (write-only) — the ONLY Shell state a
    #     command may rebind. Writers delegate to the Shell accessors; ctx
    #     never shadows them.
    #   · effects      : the named verbs below. Anything else raises
    #     NoMethodError — extend deliberately, together with the freeze test
    #     and the boundary guard.
    #
    # Handlers are invoked as handler.call(args, ctx). There is no
    # register_command, no ivar access and no method_missing: the interface
    # a command sees is exactly this list.
    class CommandContext
      # Shell-owned readers outside the catalog (lifecycle state, table, IO).
      SHELL_READERS = [:indexer_thread, :input, :commands].freeze

      # Derived from the SSOT at load time; frozen so the surface cannot
      # grow ad hoc.
      SERVICE_READERS = (ServiceCatalog.reader_names + SHELL_READERS).freeze

      def initialize(shell)
        @shell = shell
      end

      # Dynamic, NOT constructor-captured: with_output swaps @output before
      # the handler runs, and refresh_ui! rebinds it afterwards — freezing
      # the IO here would silently detach every command print from the
      # capture/record seam.
      def out
        @shell.output
      end
      alias output out

      # IO conveniences for stored 2-arity synthesized handlers whose source
      # contract was ->(args, out) { out.puts ... }: they now receive ctx,
      # so ctx itself must print.
      def puts(*)
        out.puts(*)
      end

      def print(*)
        out.print(*)
      end

      def flush
        out.flush if out.respond_to?(:flush)
      end

      SERVICE_READERS.each do |name|
        define_method(name) { @shell.public_send(name) }
      end

      # Read-only inspection view (overrides the loop-generated reader):
      # handlers may consult the command table (!help / !commands) but
      # never mutate it — registrations belong to the shell's spine.
      def commands
        @shell.commands.dup.freeze
      end

      # Live presentation theme (re-resolved per call: refresh_ui! may swap
      # the theme between registration and invocation).
      def theme
        @shell.theme
      end

      # ── Plugin coeffects (catalog entries expose no shell reader) ───────
      def plugin_manager
        coeffect(Rubik::Coeffects::PLUGIN_MANAGER)
      end

      def plugin_storage
        coeffect(Rubik::Coeffects::PLUGIN_STORAGE)
      end

      # ── Rebindable conversation state (write-through delegation) ────────
      def conversation_history
        @shell.conversation_history
      end

      def conversation_history=(history)
        @shell.conversation_history = history
      end

      def active_loop
        @shell.active_loop
      end

      def active_loop=(loop_instance)
        @shell.active_loop = loop_instance
      end

      def conversation_route_stamp=(stamp)
        @shell.conversation_route_stamp = stamp
      end

      # Additional Shell readers commands legitimately consult (plain reads,
      # no writers — see the rebindable block above for what IS writable).
      def agent_caller
        @shell.agent_caller
      end

      def current_model_spec
        @shell.current_model_spec
      end

      # ── Command effects (named, closed; one-line delegations) ───────────
      def stop
        @shell.stop
      end

      def execute_free_text(text)
        @shell.execute_free_text(text)
      end

      def resume_session(identifier = :latest)
        @shell.resume_session(identifier)
      end

      def refresh_ui!
        @shell.refresh_ui!
      end

      def render_step_event(step_info)
        @shell.render_step_event(step_info)
      end

      def detect_git_branch
        @shell.detect_git_branch
      end

      def sync_context_and_ast(files)
        @shell.sync_context_and_ast(files)
      end

      def sync_workspace_index!
        @shell.sync_workspace_index!
      end

      def resync_llm_route!
        @shell.resync_llm_route!
      end

      def refresh_llm_registry!
        @shell.refresh_llm_registry!
      end

      def trim_conversation_window!
        @shell.trim_conversation_window!
      end

      # Pruner apply seam (goal yolu): aşamalı budama planını turn başında,
      # orchestrator.run pencereyi tohumlamadan ÖNCE uygular (input_execution
      # yolu Shell'e doğrudan çağırır; !goal buradan geçer).
      def apply_staged_prune_plan!
        @shell.apply_staged_prune_plan!
      end

      def ask_yes_no(prompt, default: "n")
        @shell.ask_yes_no(prompt, default: default)
      end

      def orchestrator_loop(opts = {})
        @shell.orchestrator_loop(opts)
      end

      def warm_ast_graph(async: true)
        @shell.warm_ast_graph(async: async)
      end

      def build_tool_registry
        @shell.build_tool_registry
      end

      def request_paste!
        @shell.request_paste!
      end

      # The one whole-shell handoff a command may still make: the replayer
      # plants @replaying on its receiver and re-enters execute_input, so it
      # must own the real Shell — passing ctx would plant the flag on the
      # wrong object and break replay suppression.
      def session_replayer
        Rubik::Session::Replayer.new(@shell)
      end

      private

      def coeffect(key)
        Rubik::Coeffects.get(@shell.runtime_manager&.context, key)
      end
    end
  end
end
