# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestContextCompactorAndTruncation < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  # ---------------------------------------------------------------------------
  # 1. TokenEstimator Tests
  # ---------------------------------------------------------------------------
  def test_token_estimator_text
    assert_equal 0, Rubik::Prompt::TokenEstimator.estimate_text(nil)
    assert_equal 0, Rubik::Prompt::TokenEstimator.estimate_text("")

    text = "Hello world! This is a test." # 28 chars
    expected = (28 / 3.8).ceil
    assert_equal expected, Rubik::Prompt::TokenEstimator.estimate_text(text)
  end

  def test_token_estimator_message_and_history
    msg1 = { role: "system", content: "You are a helpful assistant." }
    msg2 = {
      role: "assistant",
      content: "Running tool",
      tool_calls: [{ "id" => "call_1", "name" => "read_file", "args" => { "path" => "lib/app.rb" } }]
    }
    msg3 = {
      role: "tool",
      tool_call_id: "call_1",
      tool_name: "read_file",
      content: "class App; end"
    }

    t1 = Rubik::Prompt::TokenEstimator.estimate_message(msg1)
    t2 = Rubik::Prompt::TokenEstimator.estimate_message(msg2)
    t3 = Rubik::Prompt::TokenEstimator.estimate_message(msg3)

    assert t1.positive?
    assert t2 > t1
    assert t3.positive?

    history = [msg1, msg2, msg3]
    total = Rubik::Prompt::TokenEstimator.estimate_history(history)
    assert_equal (t1 + t2 + t3), total
  end

  def test_token_estimator_tool_schemas
    schemas = [
      {
        type: "function",
        function: {
          name: "read_file",
          description: "Read file contents",
          parameters: { type: "object", properties: { path: { type: "string" } } }
        }
      }
    ]
    tokens = Rubik::Prompt::TokenEstimator.estimate_tool_schemas(schemas)
    assert tokens > 10
    assert_equal 0, Rubik::Prompt::TokenEstimator.estimate_tool_schemas([])
    assert_equal 0, Rubik::Prompt::TokenEstimator.estimate_tool_schemas(nil)
  end

  def test_token_estimator_serialization_fast_path_and_fallback
    # Fast path: normal valid UTF-8 objects
    tool_calls = [
      { id: "call_123", name: "bash", args: { "cmd" => "ls -la" } }
    ]
    fast_json = Rubik::Prompt::TokenEstimator.serialize_for_estimation(tool_calls)
    assert_equal JSON.generate(tool_calls), fast_json

    # String input pass-through
    assert_equal "plain text", Rubik::Prompt::TokenEstimator.serialize_for_estimation("plain text")

    # Fallback path: malformed UTF-8 triggers rescue to safe_json_generate
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    bad_tool_calls = [{ "name" => "tool", "arg" => malformed }]
    fallback_json = Rubik::Prompt::TokenEstimator.serialize_for_estimation(bad_tool_calls)
    assert_equal Rubik::Platform.safe_json_generate(bad_tool_calls), fallback_json
  end

  # ---------------------------------------------------------------------------
  # 2. ContextCompactor Ceiling & Needs Compaction Tests
  # ---------------------------------------------------------------------------
  def test_effective_input_ceiling
    ceiling = Rubik::Prompt::ContextCompactor.effective_input_ceiling(
      context_limit: 32_768,
      max_output_tokens: 4_096,
      safety_margin: 1_024
    )
    assert_equal 27_648, ceiling

    # Minimum floor test
    low_ceiling = Rubik::Prompt::ContextCompactor.effective_input_ceiling(
      context_limit: 2_000,
      max_output_tokens: 4_096,
      safety_margin: 1_024
    )
    assert_equal 1_024, low_ceiling
  end

  def test_needs_compaction
    short_history = [
      { role: "system", content: "Short system prompt" },
      { role: "user", content: "Hello" }
    ]
    refute Rubik::Prompt::ContextCompactor.needs_compaction?(
      short_history,
      context_limit: 32_768,
      max_output_tokens: 4_096,
      safety_margin: 1_024,
      max_tokens_ratio: 0.85
    )

    # Giant history
    giant_content = "X" * 120_000
    long_history = [
      { role: "system", content: "System prompt" },
      { role: "user", content: giant_content }
    ]
    assert Rubik::Prompt::ContextCompactor.needs_compaction?(
      long_history,
      context_limit: 32_768,
      max_output_tokens: 4_096,
      safety_margin: 1_024,
      max_tokens_ratio: 0.85
    )
  end

  # ---------------------------------------------------------------------------
  # 3. Compact History Strategies
  # ---------------------------------------------------------------------------
  def test_compact_history_strategy_off
    history = [
      { role: "system", content: "System prompt" },
      { role: "user", content: "Huge prompt " * 5000 }
    ]
    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history,
      context_limit: 10_000,
      config: { "compaction_strategy" => "off" }
    )
    assert_equal history.size, compacted.size
    assert_equal history.last[:content], compacted.last[:content]
  end

  def test_compact_history_prune_tool_results
    large_tool_output = "Line content data\n" * 500 # ~9000 chars
    history = [
      { role: "system", content: "System prompt" },                # Index 0 (preserve_first_n)
      { role: "user", content: "Run analysis" },                   # Index 1 (preserve_first_n)
      { role: "assistant", content: "Running...", tool_calls: [{ "name" => "tool_1" }] },
      { role: "tool", tool_call_id: "c1", content: large_tool_output }, # Intermediate tool result -> should be pruned
      { role: "assistant", content: "Next step", tool_calls: [{ "name" => "tool_2" }] },
      { role: "tool", tool_call_id: "c2", content: large_tool_output }, # Intermediate tool result -> should be pruned
      { role: "assistant", content: "Final answer" },              # Index 6
      { role: "user", content: "Thanks" }                          # Index 7 (last)
    ]

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history,
      context_limit: 4_000, # Small limit to trigger compaction
      max_output_tokens: 1_000,
      safety_margin: 500,
      config: {
        "compaction_strategy" => "prune_tool_results",
        "tool_result_prune_chars" => 1000,
        "preserve_first_n" => 2,
        "preserve_last_n" => 2
      }
    )

    assert_equal history.size, compacted.size
    # Intermediate tool results should be pruned
    assert compacted[3][:content].length < large_tool_output.length
    assert_includes compacted[3][:content], "Truncated"
  end

  def test_compact_history_atomic_tool_pairing_preservation
    # History with assistant calling a tool and its matching tool result
    history = [
      { role: "system", content: "System" },                       # Head
      { role: "user", content: "Task 1" },                         # Head
      { role: "assistant", content: "Calling A", tool_calls: [{ "id" => "a1", "name" => "toolA" }] }, # Inter A
      { role: "tool", tool_call_id: "a1", content: "Result A" * 1000 }, # Inter A
      { role: "assistant", content: "Calling B", tool_calls: [{ "id" => "b1", "name" => "toolB" }] }, # Inter B
      { role: "tool", tool_call_id: "b1", content: "Result B" * 1000 }, # Inter B
      { role: "assistant", content: "Calling C", tool_calls: [{ "id" => "c1", "name" => "toolC" }] }, # Tail C
      { role: "tool", tool_call_id: "c1", content: "Result C" },                                        # Tail C
      { role: "assistant", content: "Finished all tasks!" }                                             # Tail
    ]

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history,
      context_limit: 3_000,
      max_output_tokens: 500,
      safety_margin: 200,
      config: {
        "compaction_strategy" => "sliding_window",
        "preserve_first_n" => 2,
        "preserve_last_n" => 3
      }
    )

    # Check that <compacted_summary> was inserted
    summary_msg = compacted.find { |m| m[:content]&.include?("<compacted_summary") }
    assert summary_msg, "Expected <compacted_summary> tag in compacted history"

    # Verify no dangling tool messages: every tool message must have preceding assistant tool_calls
    compacted.each_with_index do |msg, idx|
      next unless msg[:role] == "tool"

      prev_msg = compacted[idx - 1]
      assert((prev_msg[:role] == "assistant" && prev_msg[:tool_calls]) || prev_msg[:role] == "tool",
             "Dangling tool message found at index #{idx} without preceding assistant tool_calls")
    end
  end

  def test_emergency_compact
    large_str = "A" * 5000
    history = [
      { role: "system", content: "System" },
      { role: "user", content: "User query" },
      { role: "assistant", content: large_str },
      { role: "tool", tool_call_id: "c1", content: large_str },
      { role: "tool", tool_call_id: "c2", content: large_str }
    ]

    before_tokens = Rubik::Prompt::TokenEstimator.estimate_history(history)
    Rubik::Prompt::EmergencyCompactor.compact!(history)
    after_tokens = Rubik::Prompt::TokenEstimator.estimate_history(history)

    assert after_tokens < (before_tokens * 0.5), "Emergency compact should reduce token count by >50%"
    assert history[3][:content].length <= 500
    assert history[4][:content].length <= 500
  end

  # ---------------------------------------------------------------------------
  # 4. LLM Registry & Router Tests
  # ---------------------------------------------------------------------------
  def test_llm_registry_max_output_and_ceiling
    registry = Rubik::LLM::Registry.new
    assert_equal 16_384, registry.max_output_tokens_for("anthropic")
    assert_equal 16_384, registry.max_output_tokens_for("openai")
    assert_equal 8_192, registry.max_output_tokens_for("ollama")

    limit = registry.effective_input_limit_for("anthropic", "claude-3-5-sonnet")
    # 200_000 - 16_384 - 1_024 = 182_592
    assert_equal 182_592, limit
  end

  def test_router_includes_max_output_tokens
    config = Rubik::Config.new(root_dir: @temp_dir)
    router = Rubik::LLM::Router.new(config: config)
    routed = router.route(prompt: "fast check")

    assert routed.key?(:max_output_tokens)
    assert routed[:max_output_tokens].positive?
    assert routed.key?(:context_limit)
  end

  # ---------------------------------------------------------------------------
  # 5. Orchestrator Loop Auto-Recovery on Context Overflow
  # ---------------------------------------------------------------------------
  class MockOverflowProvider
    attr_reader :call_count

    def initialize
      @call_count = 0
    end

    def complete(_history, _opts = {})
      @call_count += 1
      raise Rubik::LLM::ClientError, "HTTP Request failed with code 400: prompt is too long, maximum context limit exceeded" if @call_count == 1

      # Second call succeeds
      MockResponse.new("Success after emergency compaction")
    end
  end

  class MockResponse
    attr_reader :text, :usage

    def initialize(text)
      @text = text
      @usage = { input_tokens: 50, output_tokens: 20 }
    end

    def tool_calls?
      false
    end

    def tool_calls
      []
    end
  end

  def test_orchestrator_loop_auto_recovers_on_context_overflow
    provider = MockOverflowProvider.new
    registry = Rubik::Tools::Registry.new

    emergency_events = []
    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: registry,
      context_limit: 8_000,
      on_step: ->(info) { emergency_events << info if info[:type] == :emergency_compact }
    )

    res = orchestrator.run("Test prompt")
    assert res[:ok]
    assert_equal "Success after emergency compaction", res[:output]
    assert_equal 2, provider.call_count
    assert_equal 1, emergency_events.size
  end

  # Plan 63 Faz A: the loop passes its context budget into the emergency
  # compactor, so the retry event discloses which layer did the work. The
  # exact layer is content-dependent — on a fresh history the generated
  # system prompt alone can exceed the estimate threshold, sending the
  # (mutation-free for system/user roles) hard-truncation layer last.
  def test_emergency_compact_event_reports_compaction_layer
    provider = MockOverflowProvider.new
    emergency_events = []
    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: Rubik::Tools::Registry.new,
      context_limit: 8_000,
      on_step: ->(info) { emergency_events << info if info[:type] == :emergency_compact }
    )

    res = orchestrator.run("Test prompt")
    assert res[:ok]
    assert_includes [:structural, :hard_truncate], emergency_events.first[:layer]
  end

  # ---------------------------------------------------------------------------
  # 6. Shell !context Commands
  # ---------------------------------------------------------------------------
  def test_shell_context_status_and_compact_commands
    output = StringIO.new
    shell = Rubik::REPL::Shell.new(root_dir: @temp_dir, output: output)

    # Test !context status
    output.reopen
    shell.execute_input("!context")
    status_out = output.string
    assert_includes status_out, "LLM Context Window & In-Memory Status"
    assert_includes status_out, "Usable Input Ceiling:"
    assert_includes status_out, "Compaction Strategy:"
    assert_includes status_out, "%"

    # Add large history to shell and test !context compact
    large_turn = "Turn content " * 500
    shell.conversation_history << { role: "assistant", tool_calls: [{ "name" => "test" }] }
    shell.conversation_history << { role: "tool", tool_call_id: "1", content: large_turn }
    shell.conversation_history << { role: "assistant", tool_calls: [{ "name" => "test" }] }
    shell.conversation_history << { role: "tool", tool_call_id: "2", content: large_turn }
    shell.conversation_history << { role: "assistant", content: "End" }

    output.reopen
    shell.execute_input("!context compact")
    compact_out = output.string
    assert_includes compact_out, "Context compaction completed:"
    assert_includes compact_out, "tokens"

    # Test !context drop
    output.reopen
    shell.execute_input("!context drop non_existent_file.rb")
    assert_includes output.string, "Removed non_existent_file.rb from context index."
  end
end
