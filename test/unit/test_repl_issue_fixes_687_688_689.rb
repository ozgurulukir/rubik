# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "tmpdir"

# Focused regression coverage for REPL/config findings in issues #687-689:
# agent-reachable policy gates, honest command reporting and argument parsing.
class TestReplIssueFixes687688689 < Minitest::Test
  FAKE_KEY = "sk-test-issue-fixes"

  def setup
    @root = Dir.mktmpdir("rubik-issues-root-")
    @home = Dir.mktmpdir("rubik-issues-home-")
    @out = StringIO.new
    @config = Rubik::Config.new(root_dir: @root, home_dir: @home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out, root_dir: @root)
    Rubik::Security::SecretStore.backend = MemoryBackend.new
  end

  def teardown
    @shell&.stop
    Rubik::Security::SecretStore.reset!
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def reset_out
    @out.truncate(0)
    @out.rewind
  end

  def agent_ctx
    @shell.agent_caller = true
    Rubik::REPL::CommandContext.new(@shell)
  end

  # --- #687 ----------------------------------------------------------------

  def test_agent_cannot_set_provider_model_router_or_agent_config
    ctx = agent_ctx
    handler = @shell.commands["config"][:handler]
    ["providers.openai.endpoint", "models.default.provider", "model.name", "router.mode", "agent.max_steps",
     "llm.headers.X", "workspace.rw_allowed_dirs"].each do |key|
      reset_out
      handler.call(["set", key, "https://evil.example"], ctx)
      assert_includes @out.string, "Security Error", "#{key} must be operator-only"
      assert_includes @out.string, "operator-only"
    end
    assert_nil @config.fetch("providers.openai.endpoint")
  end

  def test_human_can_still_set_provider_endpoint
    @shell.agent_caller = false
    reset_out
    @shell.execute_input("!config set providers.openai.endpoint https://api.openai.com/v1")
    assert_includes @out.string, "Config 'providers.openai.endpoint' updated"
  end

  def test_untrusted_project_config_filter_drops_operator_only_keys
    raw = {
      "buffer" => { "auto_apply" => "always", "safe" => 1 },
      "subagents" => { "max_concurrency" => 99 },
      "skills" => { "paths" => ["/evil"], "safe" => 2 },
      "tools" => { "circuit_breaker" => { "threshold" => 1 } },
      "llm" => { "headers" => { "X-Evil" => "1" } },
      "models" => { "default" => { "provider" => "evil" } },
      "model" => { "name" => "evil" },
      "router" => { "mode" => "manual" },
      "workspace" => { "rw_allowed_dirs" => ["/evil"], "safe" => 3 },
      "ui" => { "verbosity" => "quiet" }
    }
    filtered = @config.send(:filter_untrusted_project_config, raw)

    refute filtered["buffer"].key?("auto_apply")
    assert_equal 1, filtered.dig("buffer", "safe")
    refute filtered.key?("subagents")
    assert_equal({ "safe" => 2 }, filtered["skills"])
    refute filtered["tools"].key?("circuit_breaker")
    refute filtered["llm"].key?("headers")
    ["models", "model", "router"].each { |k| refute filtered.key?(k) }
    refute filtered["workspace"].key?("rw_allowed_dirs")
    assert_equal 3, filtered.dig("workspace", "safe")
    assert_equal "quiet", filtered.dig("ui", "verbosity")
  end

  def test_agent_cannot_run_destructive_all_commands_or_clear_dmesg
    sup = FakeSupervisor.new
    tasks = FakeTaskManager.new
    dmesg = FakeDmesg.new
    ctx = FakeCtx.new(agent: true, out: @out, supervisor: sup, tasks: tasks, dmesg: dmesg)

    @shell.commands["subagents"][:handler].call(["kill-all"], ctx)
    @shell.commands["tasks"][:handler].call(["kill-all"], ctx)
    @shell.commands["dmesg"][:handler].call(["clear"], ctx)

    assert_equal 0, sup.kill_all_calls
    assert_equal 0, tasks.kill_all_calls
    assert_equal 0, dmesg.clear_calls
    assert_includes @out.string, "Security Error"
  end

  def test_human_can_still_run_destructive_all_commands
    sup = FakeSupervisor.new
    tasks = FakeTaskManager.new
    dmesg = FakeDmesg.new
    ctx = FakeCtx.new(agent: false, out: @out, supervisor: sup, tasks: tasks, dmesg: dmesg)

    @shell.commands["subagents"][:handler].call(["kill-all"], ctx)
    @shell.commands["tasks"][:handler].call(["kill-all"], ctx)
    @shell.commands["dmesg"][:handler].call(["clear"], ctx)

    assert_equal 1, sup.kill_all_calls
    assert_equal 1, tasks.kill_all_calls
    assert_equal 1, dmesg.clear_calls
  end

  def test_dmesg_clear_only_counts_as_first_argument
    dmesg = FakeDmesg.new
    ctx = FakeCtx.new(agent: false, out: @out, dmesg: dmesg)
    @shell.commands["dmesg"][:handler].call(["-n", "5", "clear"], ctx)
    assert_equal 0, dmesg.clear_calls
  end

  def test_agent_lsp_gate_allows_reads_but_refuses_mutations
    lsp = FakeLspManager.new
    agent = FakeCtx.new(agent: true, out: @out, lsp: lsp, config: @config)
    @shell.commands["lsp"][:handler].call(["off", "--global"], agent)
    assert_includes @out.string, "Security Error"
    assert_equal true, @config.fetch("lsp.enabled"), "agent 'off' must not change the config"

    reset_out
    @shell.commands["lsp"][:handler].call(["status"], agent)
    refute_includes @out.string, "Security Error"
    assert_includes @out.string, "LSP Integration Status"
  end

  def test_agent_cannot_change_step_budget_or_model_routing
    ctx = agent_ctx
    reset_out
    @shell.commands["steps"][:handler].call(["100000", "--global"], ctx)
    assert_includes @out.string, "Security Error"

    reset_out
    @shell.commands["model"][:handler].call(["route", "manual", "--global"], ctx)
    assert_includes @out.string, "Security Error"
    assert_equal "auto", @config.fetch("router.mode"), "agent route change must not persist"
  end

  def test_session_find_refuses_arbitrary_existing_files
    notes = File.join(@root, "NOTES.md")
    File.write(notes, "not a session\n")
    assert_nil Rubik::Session::Manager.find_session(notes, @root, @home)

    rec = Rubik::Session::Recorder.new(session_name: "session_20260101_120000.jsonl", root_dir: @root, home_dir: @home)
    rec.record("prompt", "hello")
    assert_equal rec.session_file, Rubik::Session::Manager.find_session("session_20260101_120000", @root, @home)
    assert_equal rec.session_file, Rubik::Session::Manager.find_session("120000", @root, @home)
  end

  # --- #688 ----------------------------------------------------------------

  def test_provider_set_rejects_structural_fields_and_invalid_names
    @shell.execute_input("!provider add zz https://api.example.com")
    reset_out
    @shell.execute_input("!provider set zz models junk")
    assert_includes @out.string, "not settable"
    assert_equal [{ "name" => "default", "context_limit" => 32_768 }], @config.provider_spec("zz")["models"]

    reset_out
    @shell.execute_input("!provider set a.b endpoint https://evil.example")
    assert_includes @out.string, "Invalid provider name"
  end

  def test_provider_add_rejects_dotted_name_and_nonpositive_context
    reset_out
    @shell.execute_input("!provider add a.b https://api.example.com")
    assert_includes @out.string, "Invalid provider name"
    assert_nil @config.provider_spec("a.b")

    reset_out
    @shell.execute_input("!provider add zz2 https://api.example.com --context=abc")
    assert_includes @out.string, "positive integer"
    assert_nil @config.provider_spec("zz2")
  end

  def test_provider_add_model_rejects_nonpositive_context
    @shell.execute_input("!provider add zz3 https://api.example.com")
    ["--context=0", "--context=-5", "--context=abc"].each do |flag|
      reset_out
      @shell.execute_input("!provider add-model zz3 m1 #{flag}")
      assert_includes @out.string, "positive integer", flag
    end
    assert_equal [{ "name" => "default", "context_limit" => 32_768 }], @config.provider_spec("zz3")["models"]
  end

  def test_allow_dir_remove_reports_failed_rw_mode_persistence
    ext = File.join(@root, "outside-allow")
    FileUtils.mkdir_p(ext)
    @config.set("workspace.allowed_external_dirs", [ext], persist: false)
    @config.set("workspace.rw_allowed_dirs", [ext], persist: false)

    original_set = @config.method(:set)
    @config.define_singleton_method(:set) do |key, value, persist: nil|
      next({ ok: false, error: "disk full" }) if key == "workspace.rw_allowed_dirs"

      original_set.call(key, value, persist: persist)
    end

    out = StringIO.new
    approval = Rubik::REPL::Commands::WorkspaceApproval.new(
      path: ext, read_write: false, scope: :session, config: @config,
      buffer_manager: @shell.buffer_manager, out: out, guard: Object.new
    )
    approval.remove_allowed_dir!

    assert_includes out.string, "could not save"
    refute_includes out.string, "Removed allowed external directory"
  end

  def test_session_scope_provider_remove_keeps_global_provider_and_secret
    @shell.execute_input("!provider add g1 https://api.example.com --key=#{FAKE_KEY} --global")
    assert @config.provider_spec("g1")

    reset_out
    @shell.execute_input("!provider remove g1")
    assert_includes @out.string, "still defined in another configuration scope"
    refute_includes @out.string, "Removed provider"
    assert @config.provider_spec("g1")
    assert_equal FAKE_KEY, Rubik::Security::SecretStore.fetch("providers.g1.api_key")

    reset_out
    @shell.execute_input("!provider remove g1 --global")
    assert_includes @out.string, "Removed provider 'g1'"
    assert_nil @config.provider_spec("g1")
    assert_nil Rubik::Security::SecretStore.fetch("providers.g1.api_key")
  end

  def test_allowed_dir_mode_persists_and_bare_grant_is_read_only
    ext = Dir.mktmpdir("rubik-ext-ro-")
    begin
      @shell.execute_input("!allow-dir #{ext} --ro --global")
      assert_includes @out.string, "Mode: Read-Only"

      reloaded = Rubik::Config.new(root_dir: @root, home_dir: @home)
      manager = Rubik::Buffer::Manager.new(root_dir: @root, config: reloaded,
                                           allowed_external_dirs: reloaded.fetch("workspace.allowed_external_dirs", []))
      assert_includes manager.allowed_external_dirs, ext
      refute_includes manager.rw_allowed_dirs, ext

      reset_out
      @shell.execute_input("!allow-dir #{ext} --rw --global")
      reloaded2 = Rubik::Config.new(root_dir: @root, home_dir: @home)
      manager2 = Rubik::Buffer::Manager.new(root_dir: @root, config: reloaded2,
                                            allowed_external_dirs: reloaded2.fetch("workspace.allowed_external_dirs", []))
      assert_includes manager2.rw_allowed_dirs, ext

      other = Dir.mktmpdir("rubik-ext-bare-")
      begin
        reset_out
        @shell.execute_input("!allow-dir #{other}")
        assert_includes @out.string, "Mode: Read-Only"
      ensure
        FileUtils.remove_entry(other)
      end
    ensure
      FileUtils.remove_entry(ext)
    end
  end

  def test_policy_blocked_does_not_claim_in_memory_change
    @shell.execute_input("!provider add pj https://api.example.com")
    reset_out
    @shell.execute_input("!provider set pj key #{FAKE_KEY} --project")
    assert_includes @out.string, "no change made"
    refute_includes @out.string, "change kept for this session only"
    assert_nil Rubik::Security::SecretStore.fetch("providers.pj.api_key")
  end

  def test_sandbox_on_preserves_configured_driver
    @config.set("sandbox.driver", "docker", persist: :global)
    @shell.execute_input("!sandbox on --global")
    assert_equal "docker", @config.fetch("sandbox.driver")
  end

  def test_config_set_schema_error_is_contained_in_command
    reset_out
    @shell.execute_input("!config set ui.verbosity null")
    assert_includes @out.string, "Error:"
    refute_includes @out.string, "[REPL Error]"
  end

  def test_secrets_has_and_delete_understand_project_scope
    Rubik::Security::SecretStore.set("providers.local.api_key.project", FAKE_KEY)
    reset_out
    @shell.execute_input("!secrets has providers.local.api_key --project")
    assert_includes @out.string, "providers.local.api_key: stored"

    reset_out
    @shell.execute_input("!secrets delete providers.ghost.api_key")
    assert_includes @out.string, "not found (nothing deleted)"

    reset_out
    @shell.execute_input("!secrets delete providers.local.api_key --project")
    assert_includes @out.string, "Deleted stored secret"
    assert_nil Rubik::Security::SecretStore.fetch("providers.local.api_key.project")
  end

  # --- #689 ----------------------------------------------------------------

  def test_context_add_and_drop_report_honest_outcomes
    reset_out
    @shell.execute_input("!context add")
    assert_includes @out.string, "Usage: !context add"

    reset_out
    @shell.execute_input("!context add missing.rb")
    assert_includes @out.string, "File not found"
    refute_includes @out.string, "Added missing.rb"

    reset_out
    @shell.execute_input("!context drop missing.rb")
    assert_includes @out.string, "not in the context index"
    refute_includes @out.string, "Removed missing.rb"

    outside = File.join(Dir.tmpdir, "outside_#{Process.pid}.rb")
    File.write(outside, "x = 1\n")
    begin
      reset_out
      @shell.execute_input("!context add #{outside}")
      assert_includes @out.string, "Security Error"
      refute_includes @out.string, "Added #{outside}"
    ensure
      FileUtils.rm_f(outside)
    end
  end

  def test_failed_mcp_add_rolls_back_definition
    reset_out
    @shell.execute_input("!mcp add dummy /nonexistent/binary")
    assert_includes @out.string, "rolled back"

    reset_out
    @shell.execute_input("!mcp status")
    refute_includes @out.string, "dummy"
  end

  def test_session_save_twice_and_existing_name
    @shell.execute_input("!session save foo")
    saved = File.join(@root, ".rubik", "sessions", "foo.jsonl")
    assert File.exist?(saved)

    reset_out
    @shell.execute_input("!session save foo")
    assert_includes @out.string, "already saved"
    assert File.exist?(saved)

    reset_out
    @shell.execute_input("!session save bar")
    assert_includes @out.string, "Session saved to"
    # `foo` exists on disk but is no longer the active session file.
    reset_out
    @shell.execute_input("!session save foo")
    assert_includes @out.string, "already exists"
  end

  def test_parse_scope_keeps_mid_argument_flags
    scope, args = Rubik::REPL::Commands::Base.parse_scope(["add", "git", "commit", "-g", "--project"])
    assert_equal :project, scope
    assert_equal ["add", "git", "commit", "-g"], args
  end

  def test_typo_inputs_do_not_mutate
    reset_out
    @shell.execute_input('!allow-cmd ad "git status" --project')
    assert_includes @out.string, "Unknown !allow-cmd subcommand"
    assert_empty @config.fetch("security.command_allowlist", [])

    reset_out
    @shell.execute_input("!verbosity bogus")
    assert_includes @out.string, "Usage: !verbosity"

    reset_out
    @shell.execute_input("!steps 5abc")
    assert_includes @out.string, "Usage: !steps"

    reset_out
    @shell.execute_input("!model set bogus something")
    assert_includes @out.string, "Usage: !model set"

    original_default = @config.model_spec(:default)["name"]
    ["!model contekt 100", "!model contekt abc"].each do |input|
      reset_out
      @shell.execute_input(input)
      assert_includes @out.string, "Unknown !model form 'contekt'"
      assert_equal original_default, @config.model_spec(:default)["name"]
    end
  end

  def test_model_switch_accepts_only_known_provider_as_first_token
    registry = Object.new
    registry.define_singleton_method(:list) { ["ollama", "openrouter"] }
    ctx = Object.new
    ctx.define_singleton_method(:llm_registry) { registry }
    ctx.define_singleton_method(:config) { nil }
    mod = Rubik::REPL::Commands::AgentModels

    assert mod.valid_model_switch_args?(["llama3"], ctx), "a single token is a model name"
    assert mod.valid_model_switch_args?(["ollama", "llama3"], ctx)
    assert mod.valid_model_switch_args?(["openrouter", "anthropic/claude"], ctx)
    refute mod.valid_model_switch_args?(["contekt", "100"], ctx)
    refute mod.valid_model_switch_args?(["contekt", "abc"], ctx)
  end

  def test_mcp_unknown_servers_report_not_found
    reset_out
    @shell.execute_input("!mcp disconnect nosuch")
    assert_includes @out.string, "not found"
    reset_out
    @shell.execute_input("!mcp remove nosuch")
    assert_includes @out.string, "not found"
  end

  def test_plugin_enable_disable_admit_no_effect
    reset_out
    @shell.execute_input("!plugin enable ghost")
    assert_includes @out.string, "not implemented"
    refute_includes @out.string, "enabled (placeholder)"

    reset_out
    @shell.execute_input("!plugin disable ghost")
    assert_includes @out.string, "not implemented"
  end

  def test_plan_defaults_to_no_without_explicit_approval
    # Non-interactive ask_yes_no returns its default; "y" would execute an
    # unapproved plan (issue #684 finding 2).
    router = Object.new
    router.define_singleton_method(:route) { |**| { provider: nil, role: "default", model: "m" } }
    @shell.define_singleton_method(:router) { router }
    loop_obj = Object.new
    loop_obj.define_singleton_method(:run) { |_task, **| { ok: true, output: "1. do the thing" } }
    @shell.define_singleton_method(:orchestrator_loop) { |*| loop_obj }
    captured = nil
    @shell.define_singleton_method(:ask_yes_no) do |_prompt, default:|
      captured = default
      default
    end

    reset_out
    @shell.execute_input("!plan do the thing")
    assert_equal "n", captured
    assert_includes @out.string, "Plan cancelled"
    refute_includes @out.string, "Executing approved plan"
  end

  def test_mcp_connect_refuses_to_replace_configured_definition
    @shell.execute_input("!mcp add cfgd #{RbConfig.ruby} /nonexistent/server.rb")
    # The add fails to start and rolls back, so use a stub manager instead.
    manager = Object.new
    manager.define_singleton_method(:servers) { { "cfgd" => {} } }
    manager.define_singleton_method(:connect) { |*| raise "should not be called" }
    ctx = FakeCtx.new(agent: false, out: @out, mcp: manager)
    reset_out
    @shell.commands["mcp"][:handler].call(["connect", "cfgd", "ruby", "server.rb"], ctx)
    assert_includes @out.string, "already configured"
  end

  def test_plugin_remove_requires_confirmation
    storage = Object.new
    storage.define_singleton_method(:remove_plugin) { |*, **| raise "should not delete" }
    manager = Object.new
    manager.define_singleton_method(:unload_plugin) { |*, **| false }
    ctx = FakeCtx.new(agent: false, out: @out, plugin_manager: manager, plugin_storage: storage)
    ctx.define_singleton_method(:ask_yes_no) { |*, **| "n" }
    reset_out
    @shell.commands["plugin"][:handler].call(["remove", "ghost"], ctx)
    assert_includes @out.string, "Cancelled"
  end

  # --- doubles -------------------------------------------------------------

  class MemoryBackend
    def initialize
      @saved = {}
    end

    def write(name, value) = @saved[name] = value
    def read(name) = @saved[name]

    def delete(name)
      @saved.delete(name)
      true
    end
  end

  class FakeSupervisor
    attr_reader :kill_all_calls

    def initialize = @kill_all_calls = 0
    def kill_all = @kill_all_calls += 1
  end

  class FakeTaskManager
    attr_reader :kill_all_calls

    def initialize = @kill_all_calls = 0
    def kill_all = @kill_all_calls += 1
  end

  class FakeDmesg
    attr_reader :clear_calls

    def initialize = @clear_calls = 0
    def clear! = @clear_calls += 1
    def tail(*) = []
  end

  class FakeLspManager
    def status_summary = { enabled: false, servers: {} }
  end

  class FakeCtx
    attr_reader :out, :dmesg, :config, :plugin_manager, :plugin_storage

    def initialize(agent:, out:, supervisor: nil, tasks: nil, dmesg: nil, lsp: nil, config: nil,
                   mcp: nil, plugin_manager: nil, plugin_storage: nil)
      @agent = agent
      @out = out
      @supervisor = supervisor
      @tasks = tasks
      @dmesg = dmesg
      @lsp = lsp
      @config = config
      @mcp = mcp
      @plugin_manager = plugin_manager
      @plugin_storage = plugin_storage
    end

    def agent_caller = @agent
    def subagent_supervisor = @supervisor
    def task_manager = @tasks

    def lsp_manager = @lsp

    def mcp_manager = @mcp
  end
end
