# frozen_string_literal: true

# Shared two-channel turn harness (the agent-turn-executor plan): runs one
# scripted provider response sequence through BOTH channels — the user
# channel (a real Loop over a throwaway workspace) and the subagent channel
# (an Instance driven synchronously on the calling thread) — and returns
# the observation handles so scenario tests can assert shared invariants
# per channel. Mirrors the scripted_agent_harness precedent: required once
# from test_helper, defines classes only, no boot-time side effects.
module Rubik
  module TestSupport
    module TurnScenarioHarness
      Observation = Struct.new(:user_loop, :user_events, :user_result, :subagent, keyword_init: true)

      # Replays prepared Rubik::LLM::Response turns verbatim; falls back to
      # a finish call when the script runs dry so an under-scripted test
      # fails on assertions rather than on a nil deref.
      class ScriptedTurnProvider < LLM::BaseProvider
        DEFAULT_FINISH = LLM::Response.new(text: '{"tool": "finish", "args": {"message": "done"}}')

        def initialize(responses)
          super()
          @responses = Array(responses).dup
        end

        def complete(_messages, _opts = {})
          item = @responses.shift || DEFAULT_FINISH
          raise item if item.is_a?(Exception)

          item
        end
      end

      module_function

      # Runs `responses` (LLM::Response turns) through both channels.
      #
      # User channel: a full scripted Loop#run over a throwaway workspace
      # (batch path — streaming disabled in the shell config).
      # Subagent channel: the worker's step loop runs synchronously —
      # transition! to :running, then execute_steps_with_provider on the
      # calling thread — so scenarios are thread-flake-free.
      def run_scripted_through_both_channels(root_dir:, responses:, max_steps: 6)
        user_events = []
        user_loop = build_user_loop(root_dir: root_dir, responses: responses, max_steps: max_steps, on_step: ->(e) { user_events << e })
        user_result = user_loop.run("scripted turn scenario")

        subagent = build_subagent(root_dir: root_dir, responses: responses, max_steps: max_steps)
        subagent.execute_steps_with_provider

        Observation.new(user_loop: user_loop, user_events: user_events, user_result: user_result, subagent: subagent)
      end

      def build_user_loop(root_dir:, responses:, max_steps:, on_step:)
        buffer = Buffer::Manager.new(root_dir: root_dir)
        shell = Struct.new(:buffer_manager, :snapshot_store, :context_index, :lsp_manager, :config, :runtime_manager, :commands).new(
          buffer, nil, nil, nil, { "llm.stream" => false }, nil, nil
        )
        Orchestrator::Loop.new(
          provider: ScriptedTurnProvider.new(responses),
          tool_registry: default_registry(buffer),
          max_steps: max_steps,
          on_step: on_step,
          shell: shell,
          context_limit: 16_000,
          max_output_tokens: 2_000
        )
      end

      def build_subagent(root_dir:, responses:, max_steps:)
        buffer = Buffer::Manager.new(root_dir: root_dir)
        inst = Orchestrator::Subagent::Instance.new(
          id: "turn-exec-probe", parent_id: "agent-0", role: "Turn Probe", type_name: "coder",
          prompt: "scripted turn scenario", context: nil, tool_registry: default_registry(buffer),
          max_steps: max_steps, root_dir: root_dir, provider: ScriptedTurnProvider.new(responses)
        )
        inst.transition!(:running)
        inst
      end

      def default_registry(buffer)
        registry = Tools::Registry.new
        registry.register(Tools::ReadFileTool.new(buffer))
        registry.register(Tools::FinishTool.new)
        registry
      end
    end
  end
end
