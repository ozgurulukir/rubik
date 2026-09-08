# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Plan 85 — Tool Bağlam Netliği ve Devam Sürekliliği.
# Kök neden: turn içi @history'deki tool ara adımları conversation_history'ye hiç
# akmıyordu; continue'da model bağlamı göremediği için sıfırdan keşfe başlıyordu.
# Bu dosya D-1/D-2/D-3/D-5/D-7 davranışlarını test eder.
class TestToolContextContinuity < Minitest::Test
  # ── D-1: OllamaFormatter tool prefix'i ──────────────────────────────
  def test_ollama_formatter_adds_tool_result_prefix
    formatter = Rubik::LLM::OllamaFormatter.new
    msgs = [{ role: "tool", tool_name: "list_files", content: "<tool_result tool='list_files'>...</tool_result>" }]

    formatted = formatter.format_messages(msgs)

    assert_equal "user", formatted[0]["role"]
    assert_includes formatted[0]["content"], "[Tool result: list_files]"
    assert_includes formatted[0]["content"], "<tool_result tool='list_files'>"
  end

  def test_ollama_formatter_default_label_when_no_tool_name
    formatter = Rubik::LLM::OllamaFormatter.new
    msgs = [{ role: "tool", content: "Search results" }]

    formatted = formatter.format_messages(msgs)

    assert_includes formatted[0]["content"], "[Tool result: Tool]"
  end

  # ── D-5: OpenAIFormatter tool_native flag'i ─────────────────────────
  def test_openai_formatter_tool_native_default_keeps_tool_role
    formatter = Rubik::LLM::OpenAIFormatter.new # varsayılan tool_native: true
    msgs = [{ role: "tool", tool_call_id: "c1", content: "ok" }]

    formatted = formatter.format_messages(msgs)

    assert_equal "tool", formatted[0]["role"]
    assert_equal "c1", formatted[0]["tool_call_id"]
  end

  def test_openai_formatter_tool_native_false_uses_user_prefix
    formatter = Rubik::LLM::OpenAIFormatter.new(tool_native: false)
    msgs = [{ role: "tool", tool_name: "read_file", content: "data" }]

    formatted = formatter.format_messages(msgs)

    assert_equal "user", formatted[0]["role"]
    assert_equal "[Tool result: read_file]\ndata", formatted[0]["content"]
  end

  def test_openai_compatible_provider_passes_tool_native_false_to_formatter
    provider = Rubik::LLM::OpenAICompatibleProvider.new(tool_native: false)
    assert_equal false, provider.formatter.tool_native

    # config'den tool_native:false geldiğinde fetch false'u korur (truthy bug yok)
    provider2 = Rubik::LLM::OpenAICompatibleProvider.new(tool_native: false, model: "m")
    refute provider2.formatter.tool_native
  end

  # ── D-2: ActivityLog kronolojik özet ────────────────────────────────
  def test_activity_log_chronological_summary_keeps_per_call_order
    log = Rubik::Orchestrator::ActivityLog.new
    log.record("list_files", {}, :ok)
    log.record("read_file", {}, :ok)
    log.record("read_file", {}, :ok)

    summary = log.chronological_summary

    # read_file iki kez AYRI satırda görünür — @entries per-call sırayı korur.
    assert_equal 3, summary.lines.count
    assert_includes summary, "1. list_files"
    assert_includes summary, "2. read_file"
    assert_includes summary, "3. read_file"
  end

  def test_activity_log_chronological_summary_truncates_with_more_marker
    log = Rubik::Orchestrator::ActivityLog.new
    log.record("list_files", {}, :ok)
    log.record("read_file", {}, :ok)
    log.record("write_file", {}, :ok)

    summary = log.chronological_summary(max_entries: 2)

    assert_includes summary, "... (1 more)"
    assert_equal 3, summary.lines.count # 2 satır + "... (1 more)"
    refute_includes summary, "3. write_file"
  end

  def test_activity_log_chronological_summary_empty_when_no_calls
    log = Rubik::Orchestrator::ActivityLog.new
    assert_equal "", log.chronological_summary
  end

  # ── D-3 + D-7: Shell entegrasyonu (gerçek Shell + stub router) ──────
  def setup
    @temp_dir = Dir.mktmpdir("rubik_ctx_cont")
    @temp_home = Dir.mktmpdir("rubik_ctx_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  # ── D-7: merge_turn_tool_history! doğrudan ──────────────────────────
  def test_merge_turn_tool_history_appends_tool_messages
    turn_history = [
      { role: "user", content: "list files" },
      { role: "assistant", content: nil, tool_calls: [{ tool: "list_files" }] },
      { role: "tool", tool_name: "list_files", content: "<files>" }
    ]

    result = @shell.merge_turn_tool_history!(turn_history, max_entries: 5)

    assert result
    contents = @shell.conversation_history.map { |m| m[:role] }
    assert_includes contents, "tool"
  end

  def test_merge_turn_tool_history_respects_max_entries
    # Gerçek dünyada conversation_history her turn'ün user mesajıyla başlar;
    # tool mesajları ondan sonra concat edilir. Trim, lead'deki user'ı korur.
    @shell.record_turn_outcome!("do work", "assistant reply")
    turn_history = 5.times.map { |i| { role: "tool", tool_name: "t#{i}", content: "x" } }

    @shell.merge_turn_tool_history!(turn_history, max_entries: 2)

    tools = @shell.conversation_history.select { |m| m[:role] == "tool" }
    assert_equal 2, tools.size
  end

  def test_merge_turn_tool_history_no_op_when_disabled_by_config
    @config.set("context.merge_turn_tool_history", false)
    turn_history = [{ role: "tool", tool_name: "run_command", content: "out" }]

    result = @shell.merge_turn_tool_history!(turn_history)

    assert_equal false, result
    refute(@shell.conversation_history.any? { |m| m[:role] == "tool" })
  end

  # ── D-3: record_failed_turn! kronoloji ekleme ───────────────────────
  def test_record_failed_turn_includes_tool_calls_made_when_chronicle_present
    activity = Rubik::Orchestrator::ActivityLog.new
    activity.record("list_files", {}, :ok)
    activity.record("read_file", {}, :ok)
    orchestrator = stub_orchestrator(activity)

    @shell.record_failed_turn!("look at files", "incomplete", "Empty response from model", orchestrator)

    hist = @shell.conversation_history
    assert_includes hist[1][:content], "[Turn incomplete: Empty response from model]"
    assert_includes hist[1][:content], "Tool calls made:"
    assert_includes hist[1][:content], "1. list_files"
  end

  def test_record_failed_turn_skips_tool_calls_made_when_chronicle_empty
    activity = Rubik::Orchestrator::ActivityLog.new
    orchestrator = stub_orchestrator(activity)

    @shell.record_failed_turn!("look at files", "incomplete", "boom", orchestrator)

    refute_includes @shell.conversation_history[1][:content], "Tool calls made:"
  end

  def test_record_failed_turn_preserves_existing_prefix_and_disables_chronicle
    @config.set("context.tool_chronicle_in_history", false)
    activity = Rubik::Orchestrator::ActivityLog.new
    activity.record("read_file", { "path" => "a.rb" }, :ok)
    orchestrator = stub_orchestrator(activity)

    @shell.record_failed_turn!("read x", "failed", "err", orchestrator)

    content = @shell.conversation_history[1][:content]
    # D-3 1. düzeltme: mevcut metin aynen korunur
    assert_includes content, "Partial progress before this outcome:"
    # chronicle kapalıyken "Tool calls made:" eklenmez
    refute_includes content, "Tool calls made:"
    # ama özet (summary) yine de korunur
    assert_includes content, "Tools used:"
  end

  private

  def stub_orchestrator(activity)
    obj = Object.new
    obj.define_singleton_method(:activity) { activity }
    obj.define_singleton_method(:buffer_manager) { nil }
    obj
  end
end
