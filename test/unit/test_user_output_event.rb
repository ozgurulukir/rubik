# frozen_string_literal: true

require_relative "../test_helper"

# :user_output sözleşmesi (storage-show-surface planı A): ToolOutput.display
# döndüren araçların çıktısı kullanıcıya tam içerikle event olarak akar;
# modele giden history + :tool_result özeti yalnız stub taşır.
class TestUserOutputEvent < Minitest::Test
  def setup
    @events = []
    @history = []
    @registry = Rubik::Tools::Registry.new
    display_tool = Object.new
    display_tool.define_singleton_method(:name) { "show_thing" }
    display_tool.define_singleton_method(:execute) do |_args|
      Rubik::Tools::ToolOutput.display("BODY-1\nBODY-2\n", stub: "Rendered 2 lines to the user's terminal: showproj/review/review.1.x")
    end
    plain_tool = Object.new
    plain_tool.define_singleton_method(:name) { "plain_thing" }
    plain_tool.define_singleton_method(:execute) { |_args| "PLAIN OUT" }
    failing_tool = Object.new
    failing_tool.define_singleton_method(:name) { "failing_thing" }
    failing_tool.define_singleton_method(:execute) { |_args| Rubik::Tools::ToolOutput.error("no such entity") }
    @registry.register(display_tool)
    @registry.register(plain_tool)
    @registry.register(failing_tool)
    @executor = Rubik::Orchestrator::StepExecutor.new(loop_mock)
  end

  def loop_mock
    events = @events
    history = @history
    registry = @registry
    invalid_count = 0
    loop_mock = Object.new
    loop_mock.define_singleton_method(:tool_registry) { registry }
    loop_mock.define_singleton_method(:buffer_manager) { nil }
    loop_mock.define_singleton_method(:shell) { nil }
    loop_mock.define_singleton_method(:lsp_manager) { nil }
    loop_mock.define_singleton_method(:config) { nil }
    loop_mock.define_singleton_method(:on_step) { ->(ev) { events << ev } }
    loop_mock.define_singleton_method(:history) { history }
    loop_mock.define_singleton_method(:step_count) { 1 }
    loop_mock.define_singleton_method(:max_steps) { 40 }
    loop_mock.define_singleton_method(:total_tokens) { 0 }
    loop_mock.define_singleton_method(:invalid_tool_count) { invalid_count }
    loop_mock.define_singleton_method(:invalid_tool_count=) { |v| invalid_count = v }
    loop_mock.define_singleton_method(:last_turn_streamed) { false }
    loop_mock
  end

  def call(tool)
    @executor.execute_single_tool_call({ "tool" => tool, "args" => {}, "id" => "c-#{tool}" }, "")
  end

  def test_display_output_emits_user_event_and_stub_history
    call("show_thing")

    ev = @events.find { |e| e[:type] == :user_output }
    assert ev, ":user_output event must be emitted"
    assert_equal "BODY-1\nBODY-2\n", ev[:content], "the terminal gets the full content"
    assert_includes ev[:label], "Rendered 2 lines"

    result_ev = @events.find { |e| e[:type] == :tool_result }
    assert_equal "Rendered 2 lines to the user's terminal: showproj/review/review.1.x", result_ev[:output],
                 "the ⎿ summary line reflects the stub, not the body"
    assert_equal 1, result_ev[:line_count]

    hist = @history.last
    assert_equal :ok, hist[:status]
    assert_includes hist[:content], "Rendered 2 lines", "the model sees the stub"
    refute_includes hist[:content], "BODY-1", "the model never sees the body — that is the whole point"
  end

  def test_normal_tool_has_no_user_event
    call("plain_thing")

    refute(@events.any? { |e| e[:type] == :user_output })
    assert_includes @history.last[:content], "PLAIN OUT", "regular outputs reach the model verbatim"
  end

  def test_error_output_is_never_displayed
    call("failing_thing")

    refute @events.any? { |e| e[:type] == :user_output }, "errors stay in the model's correction loop"
    assert_equal :error, @history.last[:status]
  end

  def test_missing_output_sink_warns_instead_of_silent_drop
    registry = @registry
    history = @history
    bare = Object.new
    bare.define_singleton_method(:tool_registry) { registry }
    bare.define_singleton_method(:buffer_manager) { nil }
    bare.define_singleton_method(:shell) { nil }
    bare.define_singleton_method(:lsp_manager) { nil }
    bare.define_singleton_method(:config) { nil }
    bare.define_singleton_method(:on_step) { nil } # real Loop default: sink not wired
    bare.define_singleton_method(:history) { history }
    bare.define_singleton_method(:step_count) { 1 }
    bare.define_singleton_method(:max_steps) { 40 }
    bare.define_singleton_method(:total_tokens) { 0 }
    bare.define_singleton_method(:last_turn_streamed) { false }
    invalid_count = 0
    bare.define_singleton_method(:invalid_tool_count) { invalid_count }
    bare.define_singleton_method(:invalid_tool_count=) { |v| invalid_count = v }
    # NOTE: no on_step — the loop has no display sink.

    executor = Rubik::Orchestrator::StepExecutor.new(bare)
    _out, err = capture_io do
      executor.execute_single_tool_call({ "tool" => "show_thing", "args" => {}, "id" => "c-bare" }, "")
    end

    assert_includes err, "no :user_output sink wired",
                    "a missing sink must be visible — a silent drop turns the stub into a lie"
    assert_includes history.last[:content], "Rendered 2 lines"
  end

  def test_tool_output_display_semantics
    ok = Rubik::Tools::ToolOutput.ok("x")
    err = Rubik::Tools::ToolOutput.error("boom")
    disp = Rubik::Tools::ToolOutput.display("big content", stub: "stub text")

    refute ok.user_display?
    refute err.user_display?
    assert disp.user_display?
    assert_equal "stub text", disp.display_stub
    assert_equal "big content", disp.to_s, "the carrier stays a String holding the payload"
    assert disp.ok?
  end
end
