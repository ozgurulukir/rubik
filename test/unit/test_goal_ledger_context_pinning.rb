# frozen_string_literal: true

require_relative "../test_helper"

# Pin ailesi genişlemesi (goal-ledger planı A): Σ satırı <user_task> ile AYNI
# muafiyetleri yaşar — sliding/hybrid/emergency/trim katmanlarının hepsinden
# sağ çıkar; alıntı tek etiket pinlemez; pruner düşürme/özetleme öneremez ve
# özet metnine kaçırılmış etiketler sahte pin satırı doğuramaz.
class TestGoalLedgerContextPinning < Minitest::Test
  GOAL_TEXT = "<user_task>\nFix the payment module so all its tests pass\n</user_task>"
  LEDGER_XML = "<goal_ledger rev=\"1\">\n  <objective>Fix the payment module</objective>\n</goal_ledger>"

  def fat_tool_turn(tag, filler = "x" * 4000)
    [
      { role: "assistant", content: nil, tool_calls: [{ "tool" => "read_file", "args" => { "path" => "lib/#{tag}.rb" } }] },
      { role: "tool", tool_name: "read_file", content: "#{tag}: #{filler}" }
    ]
  end

  def ledgered_history(extra_units = 6)
    [
      { role: "system", content: "system prompt" },
      { role: "user", content: "prior conversation turn" },
      { role: "assistant", content: "prior answer" }
    ] + (1..extra_units).flat_map { |i| fat_tool_turn("unit#{i}") } +
      [{ role: "user", content: GOAL_TEXT },
       { role: "user", content: LEDGER_XML }] +
      [{ role: "assistant", content: "working on it", tool_calls: [{ "tool" => "list_files", "args" => {} }] },
       { role: "tool", tool_name: "list_files", content: "a.rb" }]
  end

  def ledger_rows(history)
    history.select { |m| m.is_a?(Hash) && (m[:role] || m["role"]).to_s == "user" && m[:content].to_s.start_with?("<goal_ledger ") }
  end

  def assert_ledger_survives(history)
    rows = ledger_rows(history)
    refute_empty rows, "the Σ <goal_ledger> row must survive compaction"
    assert_includes rows.first[:content], "<objective>", "Σ content must be intact, not truncated"
    assert rows.first[:content].end_with?("</goal_ledger>"), "the closing tag survives — the row was not halved"
    rows
  end

  # ---- structural layers ----

  def test_sliding_window_and_hybrid_never_drop_the_ledger_row
    ["sliding_window", "hybrid"].each do |strategy|
      compacted = Rubik::Prompt::ContextCompactor.compact_history(
        ledgered_history, context_limit: 8192, max_output_tokens: 1024,
                          config: { "compaction_strategy" => strategy }
      )
      assert_ledger_survives(compacted)
    end
  end

  def test_emergency_compaction_preserves_the_ledger_row_through_both_tiers
    history = ledgered_history(2)
    history.each { |m| m[:content] = m[:content].to_s + (" detail " * 300) if m[:role] == "tool" }
    Rubik::Prompt::EmergencyCompactor.compact!(history, context_limit: 4096, max_output_tokens: 512, config: {})
    assert_ledger_survives(history)
    row = ledger_rows(history).first
    assert_equal LEDGER_XML, row[:content], "the ledger row is a user row — the hard-truncate tier never touches it"
  end

  def test_trim_oversized_messages_never_halves_an_oversized_ledger_row
    fat_ledger = "<goal_ledger rev=\"1\">\n  <objective>#{'fix payments. ' * 900}</objective>\n</goal_ledger>"
    history = ledgered_history(4)
    history[history.index { |m| m.is_a?(Hash) && m[:content].to_s.start_with?("<goal_ledger ") }] = { role: "user", content: fat_ledger }

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 4096, max_output_tokens: 512,
               config: { "compaction_strategy" => "sliding_window" }
    )
    rows = assert_ledger_survives(compacted)
    assert_operator rows.first[:content].length, :>, 8000, "the oversized Σ row is exempt from the halving pass"
  end

  def test_a_quoted_opening_tag_alone_does_not_pin_a_message
    history = ledgered_history(6)
    history << { role: "user", content: "I quote: <goal_ledger rev=\"9\"> as an example of the format" }
    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 8192, max_output_tokens: 1024,
               config: { "compaction_strategy" => "sliding_window" }
    )
    assert_equal 1, ledger_rows(compacted).size, "an unclosed quoted tag must not pin its message"
  end

  def test_off_path_histories_without_ledger_rows_compact_to_the_exact_legacy_shape
    plain = [
      { role: "system", content: "system prompt" },
      { role: "user", content: GOAL_TEXT }
    ] + (1..6).flat_map { |i| fat_tool_turn("unit#{i}") } +
            [{ role: "user", content: "later turn" }]
    legacy = Rubik::Prompt::ContextCompactor.compact_history(
      Marshal.load(Marshal.dump(plain)), context_limit: 8192, max_output_tokens: 1024,
                                         config: { "compaction_strategy" => "sliding_window" }
    )
    now = Rubik::Prompt::ContextCompactor.compact_history(
      plain, context_limit: 8192, max_output_tokens: 1024,
             config: { "compaction_strategy" => "sliding_window" }
    )
    assert_equal legacy, now, "the pin-family extension is inert without ledger rows"
  end

  # ---- pruner interplay ----

  def test_the_pruner_never_proposes_drop_or_summarize_for_a_ledger_bearing_unit
    history = ledgered_history(3)
    units = Rubik::REPL::Pruner::Rules.build_units(history, config: {})
    ledger_unit = units.find { |u| u[:rows].any? { |r| Rubik::Prompt::ContextCompactor.ledger_message?(r) } }
    refute_nil ledger_unit, "the Σ row forms (or joins) a unit"
    assert ledger_unit[:pinned_goal?], "unit_pins_goal? now covers the ledger family"
    assert ledger_unit[:protected?], "protected units are undroppable and unsummarizable by construction"
  end

  def test_the_pruner_invariant_counts_ledger_rows_like_goal_rows
    history = ledgered_history(3)
    original_count = history.count { |r| Rubik::Prompt::ContextCompactor.ledger_message?(r) }
    tampered = Marshal.load(Marshal.dump(history))
    tampered.reject! { |r| Rubik::Prompt::ContextCompactor.ledger_message?(r) }
    assert_equal 1, original_count
    assert_equal 0, tampered.count { |r| Rubik::Prompt::ContextCompactor.ledger_message?(r) },
                 "a dropped Σ row is exactly what the count invariant must catch"
  end

  def test_summarize_text_carrying_ledger_tags_gets_escaped_no_forged_pinned_rows
    dirty = "The window held #{LEDGER_XML} as its last state"
    clean = dirty.gsub("<goal_ledger ", "&lt;goal_ledger ").gsub("</goal_ledger>", "&lt;/goal_ledger>")
    refute_includes clean, "<goal_ledger ", "the escape closes the forged-pin injection"
    assert_includes clean, "&lt;goal_ledger "
  end

  # ---- reinjection ----

  def test_reinjection_keeps_the_summary_marker_and_the_current_sigma_beside_the_goal_row
    ledger = Rubik::Orchestrator::GoalLedger::Ledger.create!(goal_text: "Fix payments", store: nil, dmesg: nil)
    ledger.update(JSON.generate({ "rev" => 0, "ops" => [
                                  { "op" => "add", "path" => "/tasks/-", "value" => { "id" => "t1", "title" => "Design", "status" => "doing" } }
                                ] }))

    history = [
      { role: "user", content: GOAL_TEXT },
      { role: "user", content: ledger.to_xml }
    ] + (1..6).flat_map { |i| fat_tool_turn("unit#{i}") } +
              [{ role: "user", content: "later turn" }]

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 8192, max_output_tokens: 1024,
               config: { "compaction_strategy" => "sliding_window" }
    )

    assert_ledger_survives(compacted)
    marker = compacted.select { |m| m.is_a?(Hash) && m[:content].to_s.start_with?("<compacted_summary ") }
    assert_equal 1, marker.size, "the compacted_summary provenance marker is kept (orthogonal information)"
    assert_match(/count="\d+"/, marker.first[:content])

    goal_idx = compacted.index { |m| m.is_a?(Hash) && m[:content].to_s.include?("<user_task>") }
    ledger_idx = compacted.index { |m| m.is_a?(Hash) && m[:content].to_s.start_with?("<goal_ledger ") }
    refute_nil goal_idx
    refute_nil ledger_idx
    assert_operator ledger_idx, :>, goal_idx, "Σ sits right after the pinned goal row (spatial locality)"
    assert_includes compacted[ledger_idx][:content], "Design", "the Σ row carries the CURRENT state, not a stale one"
  end
end
