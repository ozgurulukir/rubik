# frozen_string_literal: true

require_relative "../test_helper"

class TestE2EAgentWorkflow < Minitest::Test
  class ScriptedLLMClient < Rubik::LLM::BaseProvider
    def initialize(responses)
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      item = @responses.shift || { role: "assistant", content: '{"tool": "finish", "args": {"message": "done"}}' }
      text = item.is_a?(Hash) ? item[:content] : item.to_s
      Rubik::LLM::Response.new(text: text)
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_e2e_workflow")
    FileUtils.mkdir_p(File.join(@temp_dir, "lib"))

    # Initial file on disk
    File.write(
      File.join(@temp_dir, "lib", "math.rb"),
      <<~RUBY
        class MathService
          def self.add(a, b)
            a - b # Bug: should be +
          end
        end
      RUBY
    )

    @config = Rubik::Config.new(root_dir: @temp_dir)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @ast_graph = Rubik::AST::Graph.new
    @guard = Rubik::Security::Guard.new
    @runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    @adapter_registry = Rubik::Adapter::Registry.new

    @registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      context_index: @context_index,
      ast_graph: @ast_graph,
      adapter_registry: @adapter_registry,
      guard: @guard,
      sandbox_runner: @runner,
      root_dir: @temp_dir
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_multi_step_agentic_workflow_e2e
    # Scripted LLM turns:
    # 1. list_files -> discover files
    # 2. read_file -> inspect math.rb
    # 3. replace_file_content -> surgically fix the bug
    # 4. apply_buffer -> persist buffer
    # 5. finish -> complete task
    responses = [
      {
        role: "assistant",
        content: '{"tool": "list_files", "args": {"path": "lib"}}'
      },
      {
        role: "assistant",
        content: '{"tool": "read_file", "args": {"path": "lib/math.rb"}}'
      },
      {
        role: "assistant",
        content: '{"tool": "replace_file_content", "args": {"path": "lib/math.rb", "target_content": "    a - b", "replacement_content": "    a + b"}}'
      },
      {
        role: "assistant",
        content: '{"tool": "apply_buffer", "args": {}}'
      },
      {
        role: "assistant",
        content: '{"tool": "finish", "args": {"message": "Successfully fixed addition bug in MathService."}}'
      }
    ]

    llm_client = ScriptedLLMClient.new(responses)
    shell_mock = Struct.new(:buffer_manager, :snapshot_store, :context_index, :lsp_manager, :config, :runtime_manager).new(
      @buffer_manager,
      nil,
      @context_index,
      nil,
      @config,
      nil
    )

    loop_instance = Rubik::Orchestrator::Loop.new(
      provider: llm_client,
      tool_registry: @registry,
      shell: shell_mock,
      max_steps: 10
    )

    result = loop_instance.run("Please fix the addition bug in lib/math.rb")

    assert result[:ok], "E2E Agent loop should complete successfully"
    assert_equal 5, result[:steps], "Agent should have completed in exactly 5 steps"

    # Verify disk content is updated
    updated_code = File.read(File.join(@temp_dir, "lib", "math.rb"))
    assert_includes updated_code, "    a + b"
    refute_includes updated_code, "    a - b"
    refute @buffer_manager.dirty?
  end
end
