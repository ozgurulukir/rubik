# frozen_string_literal: true

require_relative "../test_helper"

# The finish path must report whether the finishing turn streamed its text:
# a hardcoded streamed:false made free-text turns print the final answer
# twice (once via live chunks, once via the post-loop markdown render).
class TestFinishStreamedFlag < Minitest::Test
  def test_batch_finish_reports_streamed_false
    provider = Class.new do
      def complete(_history, _opts = {})
        Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
          '{"tool": "finish", "args": { "message": "All done" }}',
          true,
          [{ "tool" => "finish", "args": { "message": "All done" } }],
          nil
        )
      end
    end.new

    res = run_loop(provider)
    assert res[:ok]
    assert_equal false, res[:streamed], "batch finish must remain eligible for the post-loop render"
  end

  def test_streamed_finish_reports_streamed_true
    # A streaming provider whose chunks carry the finish tool call: the text
    # was already printed live, so the loop must flag streamed=true and the
    # caller must not print the same answer again.
    provider = Class.new do
      def stream_chat(_history, _opts = {}, &block)
        chunk_struct = Struct.new(:text_delta?, :text_delta, :content_delta?, :tool_use_delta, :raw, :usage)
        block.call chunk_struct.new(true, '{"tool": "finish", "args": { "message": "All done streamed" }}', false, nil, nil)
        Struct.new(:text, :has_tool_calls?, :tool_calls, :usage, :streamed).new(
          '{"tool": "finish", "args": { "message": "All done streamed" }}',
          true,
          [{ "tool" => "finish", "args": { "message": "All done streamed" } }],
          nil,
          true
        )
      end
    end.new

    res = run_loop(provider)
    assert res[:ok]
    assert_equal true, res[:streamed], "a finish turn whose text was streamed must report streamed=true"
  end

  def test_format_finish_is_single_line_and_neutral
    formatter = Rubik::REPL::StepFormatter.new(verbosity: "normal")
    out = formatter.format(
      { type: :finish, message: "First line summary\nREPORT LINE A\nREPORT LINE B" }
    )
    refute_nil out
    assert_equal 1, out.lines.count, "finish header must never re-print the multi-line answer"
    assert_includes out, "Completed: First line summary"
    assert_includes out, "(+2 more lines)"
    refute_includes out, "REPORT LINE A"
  end

  # Plan 61: a batch (not-streamed) finish renders its full answer right
  # below — the marker must not preview the body or claim "(+N more lines)"
  # as if the content were already shown above.
  def test_format_finish_batch_mode_points_below
    formatter = Rubik::REPL::StepFormatter.new(verbosity: "normal")
    out = formatter.format(
      { type: :finish, message: "First line summary\nREPORT LINE A\nREPORT LINE B", streamed: false }
    )
    refute_nil out
    assert_equal 1, out.lines.count
    assert_includes out, "full answer below"
    refute_includes out, "(+2 more lines)"
    refute_includes out, "REPORT LINE A", "batch marker must not preview the body that renders right after"
  end

  private

  def run_loop(provider)
    tool_reg = Rubik::Tools::Registry.new
    tool_reg.register(Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "finish", description: "Signal completion")
      end

      def execute(args)
        args["message"] || "Task finished"
      end
    end.new)

    loop_instance = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: tool_reg,
      max_steps: 3,
      warn_at_ratio: 0.75,
      on_step: ->(_step_info) {}
    )
    loop_instance.run("finish the task")
  end
end
