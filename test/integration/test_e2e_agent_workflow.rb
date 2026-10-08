# frozen_string_literal: true

require_relative "../test_helper"

class TestE2EAgentWorkflow < Minitest::Test
  MATH_WITH_BUG = <<~RUBY
    class MathService
      def self.add(a, b)
        a - b
      end
    end
  RUBY

  def setup
    @temp_dir = Dir.mktmpdir("rubik_e2e_workflow")
  end

  def teardown
    remove_temp_dir(@temp_dir) if File.directory?(@temp_dir)
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

    harness = Rubik::TestSupport::ScriptedAgentHarness.build_agent_loop(
      root_dir: @temp_dir,
      responses: responses,
      files: { "lib/math.rb" => MATH_WITH_BUG }
    )

    result = harness.agent_loop.run("Please fix the addition bug in lib/math.rb")

    assert result[:ok], "E2E Agent loop should complete successfully"
    # The workflow's behavior, not the exact turn count (G5/V12): the loop
    # must have executed real steps and finished inside its budget.
    assert_operator result[:steps], :>=, 1, "agent should have executed at least one step"
    assert_operator result[:steps], :<=, harness.agent_loop.max_steps, "agent should finish within the step budget"

    # Verify disk content is updated
    updated_code = File.read(File.join(@temp_dir, "lib", "math.rb"))
    assert_includes updated_code, "    a + b"
    refute_includes updated_code, "    a - b"
    refute harness.buffer_manager.dirty?
  end
end
