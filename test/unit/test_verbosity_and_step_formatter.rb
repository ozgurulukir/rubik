# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/rubik"

class TestVerbosityAndStepFormatter < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_verb_test")
    @home_dir = Dir.mktmpdir("rubik_verb_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  def test_config_verbosity_default_and_helpers
    assert_equal "normal", @config.verbosity
    assert_equal 1, @config.verbosity_level

    @config.set("ui.verbosity", "quiet")
    assert_equal "quiet", @config.verbosity
    assert_equal 0, @config.verbosity_level

    @config.set("ui.verbosity", "verbose")
    assert_equal "verbose", @config.verbosity
    assert_equal 2, @config.verbosity_level

    @config.set("ui.verbosity", "debug")
    assert_equal "debug", @config.verbosity
    assert_equal 3, @config.verbosity_level

    @config.set("ui.verbosity", "trace")
    assert_equal 3, @config.verbosity_level

    @config.set("ui.verbosity", "0")
    assert_equal 0, @config.verbosity_level

    @config.set("ui.verbosity", "2")
    assert_equal 2, @config.verbosity_level

    @config.set("ui.verbosity", "unknown_val")
    assert_equal 1, @config.verbosity_level
  end

  def test_step_formatter_level_normalization
    assert_equal Rubik::REPL::StepFormatter::LEVEL_QUIET, Rubik::REPL::StepFormatter.normalize_level("quiet")
    assert_equal Rubik::REPL::StepFormatter::LEVEL_QUIET, Rubik::REPL::StepFormatter.normalize_level("0")
    assert_equal Rubik::REPL::StepFormatter::LEVEL_QUIET, Rubik::REPL::StepFormatter.normalize_level(:quiet)

    assert_equal Rubik::REPL::StepFormatter::LEVEL_NORMAL, Rubik::REPL::StepFormatter.normalize_level("normal")
    assert_equal Rubik::REPL::StepFormatter::LEVEL_NORMAL, Rubik::REPL::StepFormatter.normalize_level("1")

    assert_equal Rubik::REPL::StepFormatter::LEVEL_VERBOSE, Rubik::REPL::StepFormatter.normalize_level("verbose")
    assert_equal Rubik::REPL::StepFormatter::LEVEL_VERBOSE, Rubik::REPL::StepFormatter.normalize_level("2")

    assert_equal Rubik::REPL::StepFormatter::LEVEL_DEBUG, Rubik::REPL::StepFormatter.normalize_level("debug")
    assert_equal Rubik::REPL::StepFormatter::LEVEL_DEBUG, Rubik::REPL::StepFormatter.normalize_level("trace")
    assert_equal Rubik::REPL::StepFormatter::LEVEL_DEBUG, Rubik::REPL::StepFormatter.normalize_level("3")

    assert_equal Rubik::REPL::StepFormatter::LEVEL_NORMAL, Rubik::REPL::StepFormatter.normalize_level("other")
  end

  def test_formatter_tool_call_by_level
    tool_call_event = {
      type: :tool_call,
      tool: "read_file",
      args: { "path" => "lib/main.rb" },
      step: 1,
      max_steps: 40,
      call_id: "call_999"
    }

    # 1. Quiet (0)
    formatter_quiet = Rubik::REPL::StepFormatter.new(verbosity: :quiet, max_steps: 40)
    assert_nil formatter_quiet.format(tool_call_event)

    # 2. Normal (1)
    formatter_normal = Rubik::REPL::StepFormatter.new(verbosity: :normal, max_steps: 40)
    normal_out = formatter_normal.format(tool_call_event)
    assert_includes normal_out, "▶ [Step 1/40] read_file (path: \"lib/main.rb\")"

    # 3. Verbose (2)
    formatter_verbose = Rubik::REPL::StepFormatter.new(verbosity: :verbose, max_steps: 40)
    verbose_out = formatter_verbose.format(tool_call_event)
    assert_includes verbose_out, "▶ [Step 1/40] Calling read_file with args: {\"path\":\"lib/main.rb\"}"

    # 4. Debug (3)
    formatter_debug = Rubik::REPL::StepFormatter.new(verbosity: :debug, max_steps: 40)
    debug_out = formatter_debug.format(tool_call_event)
    assert_includes debug_out, "[DEBUG:tool_call] step=1/40 tool=read_file call_id=call_999 args={\"path\":\"lib/main.rb\"}"
  end

  def test_formatter_tool_result_by_level
    ok_event = {
      type: :tool_result,
      tool: "read_file",
      status: :ok,
      output: "line 1\nline 2\nline 3",
      duration_ms: 15.2,
      step: 1,
      max_steps: 40,
      line_count: 3,
      byte_size: 21
    }

    error_event = {
      type: :tool_result,
      tool: "run_command",
      status: :error,
      error: "Command not found",
      output: "Error: command not found\nexit 127",
      duration_ms: 8.4,
      step: 2,
      max_steps: 40
    }

    # Quiet
    formatter_quiet = Rubik::REPL::StepFormatter.new(verbosity: :quiet)
    assert_nil formatter_quiet.format(ok_event)
    assert_nil formatter_quiet.format(error_event)

    # Normal
    formatter_normal = Rubik::REPL::StepFormatter.new(verbosity: :normal)
    normal_ok = formatter_normal.format(ok_event)
    assert_includes normal_ok, "✔ [Obs] 3 lines (15.2ms)"

    normal_err = formatter_normal.format(error_event)
    assert_includes normal_err, "✖ [Error] Command not found (8.4ms)"

    # Verbose
    formatter_verbose = Rubik::REPL::StepFormatter.new(verbosity: :verbose)
    verb_ok = formatter_verbose.format(ok_event)
    assert_includes verb_ok, "✔ [Obs] 3 lines (21 B, 15.2ms)"
    assert_includes verb_ok, "↳ Preview:"
    assert_includes verb_ok, "line 1"

    verb_err = formatter_verbose.format(error_event)
    assert_includes verb_err, "✖ [Error] Command not found (8.4ms)"
    assert_includes verb_err, "↳ Preview:"

    # Debug
    formatter_debug = Rubik::REPL::StepFormatter.new(verbosity: :debug)
    debug_ok = formatter_debug.format(ok_event)
    assert_includes debug_ok, "[DEBUG:tool_result] tool=read_file status=ok duration=15.2ms"
    assert_includes debug_ok, "line 1\nline 2\nline 3"
  end

  def test_formatter_llm_retry_by_level
    retry_event = { type: :llm_retry, attempt: 1, max: 2, reason: "Errno::ECONNRESET", step: 1, max_steps: 40 }

    assert_nil Rubik::REPL::StepFormatter.new(verbosity: :quiet).format(retry_event)

    normal_out = Rubik::REPL::StepFormatter.new(verbosity: :normal).format(retry_event)
    assert_includes normal_out, "↻ [Rubik::LLM] retry 1/2 (Errno::ECONNRESET)"

    verbose_out = Rubik::REPL::StepFormatter.new(verbosity: :verbose).format(retry_event)
    assert_includes verbose_out, "↻ [Rubik::LLM] retry 1/2 (Errno::ECONNRESET)"

    debug_out = Rubik::REPL::StepFormatter.new(verbosity: :debug).format(retry_event)
    assert_includes debug_out, "[DEBUG:llm_retry] step=1/40 retry=1/2 reason=Errno::ECONNRESET"
  end

  def test_formatter_llm_thought
    thought_event = {
      type: :llm_thought,
      content: "I should examine config.rb first.\nThen check test files.",
      step: 1,
      max_steps: 40
    }

    formatter_quiet = Rubik::REPL::StepFormatter.new(verbosity: :quiet)
    assert_nil formatter_quiet.format(thought_event)

    formatter_normal = Rubik::REPL::StepFormatter.new(verbosity: :normal)
    assert_nil formatter_normal.format(thought_event)

    formatter_verbose = Rubik::REPL::StepFormatter.new(verbosity: :verbose)
    verb_out = formatter_verbose.format(thought_event)
    assert_equal " 💭 [Thought] I should examine config.rb first.", verb_out

    formatter_debug = Rubik::REPL::StepFormatter.new(verbosity: :debug)
    debug_out = formatter_debug.format(thought_event)
    assert_equal " 💭 [Thought] I should examine config.rb first.", debug_out
  end

  def test_formatter_other_events
    # Step warning
    warn_event = { type: :step_warning, current: 30, max: 40, remaining: 10 }
    formatter = Rubik::REPL::StepFormatter.new(verbosity: :normal)
    warn_out = formatter.format(warn_event)
    assert_includes warn_out, "⚠️ [Rubik::Agent] Step budget warning: 30/40 steps used (10 remaining)."

    # Auto apply
    apply_event = { type: :auto_apply, files: ["src/app.rb", "src/util.rb"] }
    assert_nil Rubik::REPL::StepFormatter.new(verbosity: :quiet).format(apply_event)
    apply_out = formatter.format(apply_event)
    assert_includes apply_out, "⚡ [Rubik::Buffer] Auto-applied 2 modified file(s) to disk: src/app.rb, src/util.rb"

    # Emergency compact
    compact_event = { type: :emergency_compact }
    compact_out = formatter.format(compact_event)
    assert_includes compact_out, "⚠️ [Rubik::Context] Context overflow auto-recovery: applied emergency compaction to history."

    # Finish
    finish_event = { type: :finish, message: "Task completed successfully" }
    assert_nil Rubik::REPL::StepFormatter.new(verbosity: :quiet).format(finish_event)
    finish_out = formatter.format(finish_event)
    assert_includes finish_out, "🏁 [Rubik::Agent] Completed: Task completed successfully"

    # Message
    msg_event = { type: :message, content: "All tests passing" }
    assert_nil Rubik::REPL::StepFormatter.new(verbosity: :normal).format(msg_event)
    assert_nil Rubik::REPL::StepFormatter.new(verbosity: :verbose).format(msg_event)
    msg_debug = Rubik::REPL::StepFormatter.new(verbosity: :debug).format(msg_event)
    assert_includes msg_debug, "All tests passing"
  end

  def test_repl_verbosity_and_verbose_commands
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, output: out)

    # 1. !verbosity status / no args
    shell.execute_input("!verbosity")
    assert_includes out.string, "Active verbosity: normal (level 1)"
    assert_includes out.string, "0 - quiet"
    assert_includes out.string, "1 - normal"
    assert_includes out.string, "2 - verbose"
    assert_includes out.string, "3 - debug"

    # 2. !verbosity quiet
    out.reopen
    shell.execute_input("!verbosity quiet")
    assert_includes out.string, "Verbosity set to quiet (level 0)"
    assert_equal "quiet", @config.verbosity
    assert_equal 0, @config.verbosity_level

    # 3. !verbosity 2
    out.reopen
    shell.execute_input("!verbosity 2")
    assert_includes out.string, "Verbosity set to verbose (level 2)"
    assert_equal "verbose", @config.verbosity
    assert_equal 2, @config.verbosity_level

    # 4. !verbosity debug
    out.reopen
    shell.execute_input("!verbosity debug")
    assert_includes out.string, "Verbosity set to debug (level 3)"
    assert_equal "debug", @config.verbosity
    assert_equal 3, @config.verbosity_level

    # 5. !verbose on
    out.reopen
    shell.execute_input("!verbose on")
    assert_includes out.string, "Verbose mode enabled (level 2)"
    assert_equal 2, @config.verbosity_level

    # 6. !verbose off
    out.reopen
    shell.execute_input("!verbose off")
    assert_includes out.string, "Verbose mode disabled (normal, level 1)"
    assert_equal 1, @config.verbosity_level

    # 7. !verbose toggle from normal -> verbose
    out.reopen
    shell.execute_input("!verbose")
    assert_includes out.string, "Verbose mode toggled to verbose (level 2)"
    assert_equal 2, @config.verbosity_level

    # 8. !verbose toggle from verbose -> normal
    out.reopen
    shell.execute_input("!verbose")
    assert_includes out.string, "Verbose mode toggled to normal (level 1)"
    assert_equal 1, @config.verbosity_level
  end

  def test_free_text_execution_with_quiet_and_verbose_levels
    # Write a test file in @temp_dir
    File.write(File.join(@temp_dir, "app.rb"), "puts 'hello world'\nputs 'line 2'\n")

    # Mock LLM provider that issues a tool call and then finishes
    step_call_count = 0
    mock_provider = Class.new do
      define_method(:complete) do |_history, _opts = {}|
        step_call_count += 1
        if step_call_count == 1
          Struct.new(:text, :tool_calls?, :tool_calls, :usage).new(
            "Inspecting file structure...",
            true,
            [{ "tool" => "read_file", "args" => { "path" => "app.rb" }, "id" => "call_1" }],
            nil
          )
        else
          Struct.new(:text, :tool_calls?, :tool_calls, :usage).new(
            '{"tool": "finish", "args": { "message": "Done analyzing" }}',
            true,
            [{ "tool" => "finish", "args" => { message: "Done analyzing" }, "id" => "call_2" }],
            nil
          )
        end
      end
    end.new

    # Mock router
    mock_router = Object.new
    mock_router.define_singleton_method(:route) do |*_args, **_kwargs|
      {
        role: "default",
        model: "test-model",
        provider: mock_provider,
        context_limit: 4096,
        max_output_tokens: 1024
      }
    end

    # Test Quiet Mode
    @config.set("ui.verbosity", "quiet")
    out_quiet = StringIO.new
    shell_quiet = Rubik::REPL::Shell.new(config: @config, output: out_quiet, root_dir: @temp_dir)
    shell_quiet.instance_variable_set(:@router, mock_router)

    shell_quiet.execute_input("Analyze codebase")
    refute_includes out_quiet.string, "⏺"
    refute_includes out_quiet.string, "⎿"
    assert_includes out_quiet.string, "Done analyzing"

    # Test Verbose Mode
    step_call_count = 0
    @config.set("ui.verbosity", "verbose")
    out_verb = StringIO.new
    shell_verb = Rubik::REPL::Shell.new(config: @config, output: out_verb, root_dir: @temp_dir)
    shell_verb.instance_variable_set(:@router, mock_router)

    shell_verb.execute_input("Analyze codebase")
    assert_includes out_verb.string, "💭 Inspecting file structure..."
    assert_includes out_verb.string, "⏺ read_file"
    assert_includes out_verb.string, "2 lines"
    assert_includes out_verb.string, "↳ Preview:"
    # Batch provider: the finish marker must point BELOW (the post-loop
    # render follows immediately) instead of previewing "+N more lines".
    assert_includes out_verb.string, "🏁 [Rubik::Agent] Completed (full answer below)"
    assert_includes out_verb.string, "Done analyzing"
  end

  def test_finish_tool_does_not_truncate_rich_llm_response
    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        Rubik::LLM::Response.new(
          text: "Here is the complete analysis:\n1. Fixed bug in auth module\n2. Added 5 tests\nEverything is passing.",
          tool_calls: [{ "tool" => "finish", "args" => { "message" => "done" } }]
        )
      end
    end.new

    mock_router = Object.new
    mock_router.define_singleton_method(:route) do |*_args, **_kwargs|
      {
        role: "default",
        model: "test-model",
        provider: mock_provider,
        context_limit: 4096,
        max_output_tokens: 1024
      }
    end

    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, output: out, root_dir: @temp_dir)
    shell.instance_variable_set(:@router, mock_router)

    shell.execute_input("Perform analysis")
    output_str = out.string
    assert_includes output_str, "Here is the complete analysis:"
    assert_includes output_str, "1. Fixed bug in auth module"
    assert_includes output_str, "Everything is passing."
  end

  def test_formatter_thinking_event_by_level
    thinking_event = {
      type: :thinking,
      step: 1,
      max_steps: 40,
      provider: "cline",
      model: "cline-pass/deepseek-v4-flash"
    }

    # 1. Quiet (0)
    formatter_quiet = Rubik::REPL::StepFormatter.new(verbosity: :quiet, max_steps: 40)
    assert_nil formatter_quiet.format(thinking_event)

    # 2. Normal (1)
    formatter_normal = Rubik::REPL::StepFormatter.new(verbosity: :normal, max_steps: 40)
    normal_out = formatter_normal.format(thinking_event)
    assert_includes normal_out, "⏳ [Step 1/40] Thinking... (cline/cline-pass/deepseek-v4-flash)"

    # 3. Verbose (2)
    formatter_verbose = Rubik::REPL::StepFormatter.new(verbosity: :verbose, max_steps: 40)
    verbose_out = formatter_verbose.format(thinking_event)
    assert_includes verbose_out, "⏳ [Step 1/40] Querying LLM (cline/cline-pass/deepseek-v4-flash)..."

    # 4. Debug (3)
    formatter_debug = Rubik::REPL::StepFormatter.new(verbosity: :debug, max_steps: 40)
    debug_out = formatter_debug.format(thinking_event)
    assert_includes debug_out, "[DEBUG:thinking] step=1/40 provider=cline model=cline-pass/deepseek-v4-flash"
  end

  def test_formatter_condenses_security_blocked_error_to_single_line
    sec_event = {
      type: :tool_result,
      tool: "run_command",
      status: :error,
      duration_ms: 12.5,
      output: "Security blocked: `bash --version` is blocklisted by the base rule for shell interpreters, even for version checks.\n" \
              "This looks like a safe read-only probe. If intended, the operator can allowlist it once:\n  " \
              '!allow-cmd add "bash --version"'
    }

    formatter_normal = Rubik::REPL::StepFormatter.new(verbosity: :normal)
    normal_out = formatter_normal.format(sec_event)
    assert_includes normal_out, "⚠ [Security] Security blocked:"
    assert_includes normal_out, '[!allow-cmd add "bash --version"]'
    refute_includes normal_out, "✖ [Error]"
    refute_includes normal_out, "12.5ms"
    assert_equal 1, normal_out.lines.size

    formatter_verbose = Rubik::REPL::StepFormatter.new(verbosity: :verbose)
    verb_out = formatter_verbose.format(sec_event)
    assert_includes verb_out, "⚠ [Security] Security blocked:"
    assert_includes verb_out, '[!allow-cmd add "bash --version"]'
    refute_includes verb_out, "Preview:"
    assert_equal 1, verb_out.lines.size
  end
end
