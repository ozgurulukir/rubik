# frozen_string_literal: true

# Shared agent-loop test harness (G5/V13): script LLM turns, get a fully
# wired Orchestrator::Loop over a throwaway workspace. Required once from
# test_helper; defines classes only, no boot-time side effects.
module Rubik
  module TestSupport
    # Replays prepared assistant turns verbatim; falls back to a finish call
    # when the script runs dry so an under-scripted test fails on assertions
    # rather than on a nil deref.
    class ScriptedLLMClient < LLM::BaseProvider
      DEFAULT_FINISH = '{"tool": "finish", "args": {"message": "done"}}'

      def initialize(responses)
        super()
        @responses = responses.dup
      end

      def complete(_messages, _opts = {})
        item = @responses.shift || { role: "assistant", content: DEFAULT_FINISH }
        text = item.is_a?(Hash) ? item[:content] : item.to_s
        LLM::Response.new(text: text)
      end
    end

    module ScriptedAgentHarness
      Harness = Struct.new(:root_dir, :config, :buffer_manager, :context_index,
                           :registry, :agent_loop, keyword_init: true)

      module_function

      # Builds the full agent-loop stack against root_dir: writes +files+
      # ("lib/math.rb" => code), wires config/buffer/context and the default
      # tool registry, and wraps everything in a minimal shell struct.
      def build_agent_loop(root_dir:, responses:, files: {}, max_steps: 10)
        files.each { |path, code| write_fixture(root_dir, path, code) }

        config = Config.new(root_dir: root_dir)
        # This harness exercises buffer/edit mechanics, not the maestro
        # doctrine (covered by test_maestro_gate.rb): the scripted root agent
        # calls edit/execution tools directly, so the gate must be off.
        config.set("subagents.maestro_gate", false)
        buffer_manager = Buffer::Manager.new(root_dir: root_dir)
        context_index = Context::Index.new(root_dir: root_dir)
        registry = Tools::Registry.build_default(
          buffer_manager: buffer_manager,
          context_index: context_index,
          ast_graph: AST::Graph.new,
          adapter_registry: Adapter::Registry.new,
          guard: Security::Guard.new,
          sandbox_runner: Sandbox::Runner.new(root_dir: root_dir),
          root_dir: root_dir
        )
        shell = Struct.new(:buffer_manager, :snapshot_store, :context_index,
                           :lsp_manager, :config, :runtime_manager).new(
                             buffer_manager, nil, context_index, nil, config, nil
                           )
        agent_loop = Orchestrator::Loop.new(
          provider: ScriptedLLMClient.new(responses),
          tool_registry: registry,
          shell: shell,
          max_steps: max_steps
        )

        Harness.new(root_dir: root_dir, config: config, buffer_manager: buffer_manager,
                    context_index: context_index, registry: registry, agent_loop: agent_loop)
      end

      def write_fixture(root_dir, path, code)
        full_path = File.join(root_dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, code)
      end
    end
  end
end
