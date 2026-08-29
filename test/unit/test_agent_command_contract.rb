# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestAgentCommandContract < Minitest::Test
  # Plan 53 §4.1 class B: built-in commands published to the agent.
  AGENT_VISIBLE = [
    "diff", "status", "undo", "rollback", "autoapply", "context", "steps", "config", "model", "providers", "runtime", "fibers", "services", "agents", "lint", "format", "history"
  ].freeze

  class MockScriptProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text, usage: { input_tokens: 10, output_tokens: 20 })
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_contract_test")
    @temp_home = Dir.mktmpdir("rubik_contract_home")
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: @output)
    @exec_tool = Rubik::Tools::ExecReplCommandTool.new(@shell)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_audience_defaults_and_validation
    # Built-ins default to :human
    @shell.register_command("human_only_cmd", description: "operator only") {}
    assert_equal :human, @shell.commands["human_only_cmd"][:audience]

    # Custom commands default to :both
    @shell.register_command("custom_cmd", description: "synthesized", custom: true) {}
    assert_equal :both, @shell.commands["custom_cmd"][:audience]

    # Explicit audience is honored
    @shell.register_command("agent_only_cmd", description: "tool only", audience: :agent) {}
    assert_equal :agent, @shell.commands["agent_only_cmd"][:audience]

    # Invalid audience rejected
    assert_raises(ArgumentError) do
      @shell.register_command("bad_cmd", description: "x", audience: :everyone) {}
    end
  end

  def test_agent_visible_matrix_all_seventeen_registered_as_both
    AGENT_VISIBLE.each do |name|
      meta = @shell.commands[name]
      refute_nil meta, "expected '!#{name}' to be registered"
      assert_equal :both, meta[:audience], "expected '!#{name}' to be agent-visible (:both)"
    end
    assert_equal 17, AGENT_VISIBLE.size
  end

  def test_agent_visible_commands_execute_without_steering
    ["!diff", "!status", "!history"].each do |cmd|
      res = @exec_tool.execute("command" => cmd)
      refute_includes res, "Notice:", "'#{cmd}' must not be redirected"
      refute_includes res, "Blocked:", "'#{cmd}' must not be blocked"
      refute_includes res, "Unknown REPL command", "'#{cmd}' must be registered"
      refute_includes res, "reserved for the human operator", "'#{cmd}' must be agent-visible"
    end
  end

  def test_session_control_commands_hard_blocked
    @shell.conversation_history << { role: "user", content: "keep me" }
    stopped = []
    @shell.define_singleton_method(:stop) { stopped << true }

    ["quit", "exit", "clear", "reset"].each do |name|
      res = @exec_tool.execute("command" => "!#{name}")
      assert_includes res, "Blocked: '!#{name}'", "'!#{name}' must be hard-blocked for the agent"
      assert_includes res, "reserved for the human operator"
    end

    # Session state untouched: history intact, shell never stopped
    assert_equal [{ role: "user", content: "keep me" }], @shell.conversation_history
    assert_empty stopped, "blocked !quit must not stop the shell"
  end

  def test_plan_goal_block_steers_back_to_finish_tool
    ["plan", "goal"].each do |name|
      res = @exec_tool.execute("command" => "!#{name} do something")
      assert_includes res, "Nested !#{name} invocation inside tool call is blocked."
      assert_includes res, "finish", "block message must steer to the 'finish' tool"
    end
  end

  def test_custom_command_prefixed_with_plan_or_goal_stays_invokable
    @shell.register_command("plan_cache", description: "show plan cache", custom: true) do |_args|
      @shell.output.puts "cache empty"
    end

    res = @exec_tool.execute("command" => "!plan_cache")
    assert_includes res, "cache empty", "custom !plan_cache must execute, not hit the plan/goal gate"
    refute_includes res, "Nested !plan_cache invocation"
  end

  def test_human_only_commands_steer_to_operator
    ["provider", "workspace", "allow", "verbosity", "help"].each do |name|
      res = @exec_tool.execute("command" => "!#{name}")
      assert_includes res, "'!#{name}' is reserved for the human operator", "'!#{name}' must steer"
    end
  end

  def test_diagnostics_redirects_to_lsp_tool
    res = @exec_tool.execute("command" => "!diagnostics")
    assert_includes res, "Please use native tool 'lsp_diagnostics' directly"
  end

  def test_agent_commands_published_in_prompt_and_sensitive_commands_excluded
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: @shell,
      buffer_manager: @buffer_manager,
      snapshot_store: Rubik::Buffer::SnapshotStore.new,
      context_index: Rubik::Context::Index.new(root_dir: @temp_dir),
      root_dir: @temp_dir
    )

    section = prompt[%r{<agent_commands[^>]*>(.*?)</agent_commands>}m, 1]
    refute_nil section, "<agent_commands> section must be present"

    AGENT_VISIBLE.each do |name|
      assert_includes section, "!#{name}", "'!#{name}' must be published to the agent"
    end

    ["!quit", "!exit", "!clear", "!reset", "!plan", "!goal", "!allow", "!workspace", "!provider ", "!verbosity", "!help"].each do |name|
      refute_includes section, name, "'#{name}' must NOT be published to the agent"
    end
  end

  def test_agent_commands_section_token_budget
    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    tokens = Rubik::Prompt::TokenEstimator.estimate_text(xml)
    assert tokens.positive?, "agent commands XML must be generated"
    assert_operator tokens, :<=, 250, "agent commands section must stay within the Plan 53 D-7 budget, got #{tokens} tokens"
  end

  def test_custom_commands_stay_out_of_agent_commands_section
    @shell.register_command("my_custom", description: "synthesized helper", custom: true) {}

    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes xml, "<custom_commands>"
    assert_includes xml, '<command name="!my_custom">synthesized helper</command>'

    agent_section = xml[%r{<agent_commands[^>]*>(.*?)</agent_commands>}m, 1] || ""
    refute_includes agent_section, "my_custom", "custom commands must not be duplicated into <agent_commands>"
  end

  def test_goal_history_leak_removed
    responses = [
      '{"tool": "list_files", "args": {}}',
      '{"tool": "finish", "args": { "message": "Goal verified" }}'
    ]
    @shell.instance_variable_get(:@llm_registry).register("ollama", MockScriptProvider.new(responses))

    @shell.execute_input("!goal add a calculator")

    history_contents = @shell.conversation_history.map { |m| m[:content].to_s }
    goal_turn = history_contents.find { |c| c.include?("add a calculator") }
    refute_nil goal_turn, "goal text must be preserved in conversation history"
    assert_includes goal_turn, "Goal:", "user turn must use neutral 'Goal:' prefix"
    history_contents.each do |content|
      refute_includes content, "!goal", "literal bang syntax must stay out of the LLM-bound history"
    end
    assert_includes @output.string, "Goal Achieved"
  end

  def test_tracked_commands_store_bang_free_history_entries
    @shell.execute_input("!status")

    contents = @shell.conversation_history.map { |m| m[:content].to_s }
    assert_includes contents, "status", "command history entry must drop the bang prefix"
    contents.each do |content|
      refute_includes content, "!status", "literal bang syntax must stay out of the LLM-bound history"
    end
    # Session recorder still keeps the literal raw line for replay
    recorded = @shell.recorder.read_history(50).map { |i| i["payload"].to_s }
    assert recorded.any? { |p| p.include?("!status") }, "recorder must keep the literal raw command"
  end

  def test_session_restore_hydrates_bang_free_history
    require "json"
    require "time"
    sessions_dir = File.join(@temp_dir, ".rubik", "sessions")
    FileUtils.mkdir_p(sessions_dir)
    session_file = File.join(sessions_dir, "session_contract.jsonl")

    events = [
      { "ts" => Time.now.iso8601, "type" => "user_turn", "payload" => { "role" => "user", "content" => "!goal write tests" } },
      { "ts" => Time.now.iso8601, "type" => "assistant_response", "payload" => { "role" => "assistant", "content" => "Tests written" } },
      { "ts" => Time.now.iso8601, "type" => "repl_command", "payload" => { "command" => "!status", "output" => "Project: x" } }
    ]
    File.open(session_file, "w") { |f| events.each { |e| f.puts JSON.dump(e) } }

    res = Rubik::Session::Manager.restore_session(@shell, session_file)
    assert res[:ok]

    contents = @shell.conversation_history.map { |m| m[:content].to_s }
    assert_includes contents, "Goal: write tests", "goal turn must hydrate with the neutral prefix"
    assert_includes contents, "status", "repl command turn must hydrate without the bang"
    contents.each do |content|
      refute_includes content, "!goal", "restored history must not contain literal bang commands"
      refute_includes content, "!status"
    end
  end
end
