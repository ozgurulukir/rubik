# frozen_string_literal: true

require_relative "../test_helper"
require_relative "test_ui_capability"

class TestUIRenderer < Minitest::Test
  def theme
    @theme ||= Rubik::UI::Theme.new(enabled: false)
  end

  def renderer(verbosity: :normal)
    Rubik::UI::Renderer.new(verbosity: verbosity, max_steps: 40, output: StringIO.new, theme: theme)
  end

  def tool_call_event
    { type: :tool_call, tool: "read_file", args: { "path" => "lib/main.rb" },
      step: 1, max_steps: 40, call_id: "call_999" }
  end

  def tool_result_event
    { type: :tool_result, tool: "read_file", status: :ok,
      output: "line 1\nline 2\nline 3", duration_ms: 15.2,
      step: 1, max_steps: 40, line_count: 3, byte_size: 21 }
  end

  def test_quiet_level_suppresses_everything
    quiet = renderer(verbosity: :quiet)
    assert_nil quiet.render(tool_call_event)
    assert_nil quiet.render(tool_result_event)
    assert_nil quiet.render({ type: :thinking, step: 1, max_steps: 40 })
  end

  def test_tool_call_normal_uses_action_glyph_and_primary_arg
    out = renderer.render(tool_call_event)
    assert_includes out, "⏺ read_file"
    assert_includes out, "lib/main.rb"
    refute_includes out, "path"
  end

  def test_tool_call_verbose_includes_full_args
    out = renderer(verbosity: :verbose).render(tool_call_event)
    assert_includes out, "⏺ read_file"
    assert_includes out, "{\"path\":\"lib/main.rb\"}"
  end

  def test_tool_call_debug_delegates_to_legacy_formatter
    out = renderer(verbosity: :debug).render(tool_call_event)
    assert_includes out, "[DEBUG:tool_call]"
    assert_includes out, "tool=read_file"
  end

  def test_tool_result_normal_summary_line
    out = renderer.render(tool_result_event)
    assert_includes out, "⎿ 3 lines · 15.2ms"
  end

  def test_tool_result_error_line
    event = { type: :tool_result, tool: "run_command", status: :error,
              error: "Command not found", output: "boom", duration_ms: 8.4 }
    out = renderer.render(event)
    assert_includes out, "✖ Command not found (8.4ms)"
  end

  def test_tool_result_verbose_preview
    out = renderer(verbosity: :verbose).render(tool_result_event)
    assert_includes out, "3 lines (21 B, 15.2ms)"
    assert_includes out, "↳ Preview:"
    assert_includes out, "line 1"
  end

  def test_thinking_static_line_when_spinner_unavailable
    out = renderer.render({ type: :thinking, step: 2, max_steps: 40,
                            provider: "deepseek", model: "coder" })
    assert_includes out, "⏳ Düşünüyor [2/40]"
    assert_includes out, "deepseek/coder"
  end

  def test_llm_thought_only_at_verbose_and_above
    event = { type: :llm_thought, content: "Inspecting config.rb first.", step: 1, max_steps: 40 }
    assert_nil renderer.render(event)
    out = renderer(verbosity: :verbose).render(event)
    assert_includes out, "💭 Inspecting config.rb first."
  end

  def test_stable_events_keep_legacy_bodies_with_new_anchor
    finish = renderer.render({ type: :finish, message: "Task completed successfully" })
    assert_includes finish, "🏁 [Rubik::Agent] Completed: Task completed successfully"

    warning = renderer.render({ type: :step_warning, current: 30, max: 40, remaining: 10 })
    assert_includes warning, "Step budget warning: 30/40 steps used (10 remaining)."

    retry_out = renderer.render({ type: :llm_retry, attempt: 1, max: 2, reason: "ECONNRESET" })
    assert_includes retry_out, "[Rubik::LLM] retry 1/2 (ECONNRESET)"
  end

  def test_chunk_events_stop_spinner_and_stay_silent
    r = renderer
    out = r.render({ type: :chunk, delta: "tok", step: 1, max_steps: 40 })
    assert_nil out
    assert_nil r.render({ type: :chunk_end, step: 1, max_steps: 40 })
    refute r.spinner.spinning?
  end
end
