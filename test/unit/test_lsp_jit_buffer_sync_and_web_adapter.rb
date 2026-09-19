# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "fileutils"
require "rubik/buffer/manager"
require "rubik/adapter/node"
require "rubik/adapter/registry"
require "rubik/runtime/discovery"
require "rubik/config/defaults"
require "rubik/lsp/client"
require "rubik/lsp/manager"
require "rubik/tools/builtins/lsp"
require "rubik/tools/registry"
require "rubik/repl/shell"
require "rubik/repl/config_wiring"

class TestLspJitBufferSyncAndWebAdapter < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_test_p76")
    @temp_home = Dir.mktmpdir("rubik_home_p76")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if File.directory?(@temp_home)
  end

  # =========================================================================
  # 1. Buffer::Manager#dirty?(path = nil)
  # =========================================================================

  def test_buffer_manager_dirty_without_arguments
    refute @buffer_manager.dirty?

    @buffer_manager.write("file1.ts", "const a = 1;")
    assert @buffer_manager.dirty?

    @buffer_manager.apply!
    refute @buffer_manager.dirty?
  end

  def test_buffer_manager_dirty_with_path_argument
    @buffer_manager.write("file1.ts", "const a = 1;")
    File.write(File.join(@temp_dir, "file2.ts"), "const b = 2;")

    assert @buffer_manager.dirty?("file1.ts")
    assert @buffer_manager.dirty?(File.join(@temp_dir, "file1.ts"))
    refute @buffer_manager.dirty?("file2.ts")
    refute @buffer_manager.dirty?("non_existent.ts")

    # When file exists in buffer but is not written to disk
    @buffer_manager.apply!
    refute @buffer_manager.dirty?("file1.ts")

    @buffer_manager.write("file3.ts", "const c = 3;")
    assert @buffer_manager.dirty?("file3.ts")
    refute @buffer_manager.dirty?("file1.ts")
  end

  # =========================================================================
  # 2. NodeAdapter & Adapter::Registry
  # =========================================================================

  def test_node_adapter_available
    adapter = Rubik::Adapter::NodeAdapter.new
    # Node, npm or bun are standard on dev/test environments
    expected = !Rubik::Platform.which("node").nil? || !Rubik::Platform.which("npm").nil? || !Rubik::Platform.which("bun").nil?
    assert_equal expected, adapter.available?
  end

  def test_node_adapter_resolve_test_cmd_with_package_json_scripts
    adapter = Rubik::Adapter::NodeAdapter.new

    # Scenario A: scripts has "test:run" (Vitest watch guard) + pnpm-lock.yaml
    File.write(File.join(@temp_dir, "pnpm-lock.yaml"), "")
    pkg_a = { "scripts" => { "test" => "vitest", "test:run" => "vitest run" } }
    File.write(File.join(@temp_dir, "package.json"), JSON.dump(pkg_a))
    assert_equal "pnpm run test:run", adapter.resolve_test_cmd(@temp_dir)

    # Scenario B: yarn.lock + test:run
    FileUtils.rm_f(File.join(@temp_dir, "pnpm-lock.yaml"))
    File.write(File.join(@temp_dir, "yarn.lock"), "")
    assert_equal "yarn run test:run", adapter.resolve_test_cmd(@temp_dir)

    # Scenario C: bun.lockb + test:run
    FileUtils.rm_f(File.join(@temp_dir, "yarn.lock"))
    File.write(File.join(@temp_dir, "bun.lockb"), "")
    assert_equal "bun run test:run", adapter.resolve_test_cmd(@temp_dir)

    # Scenario D: package-lock.json + test:run
    FileUtils.rm_f(File.join(@temp_dir, "bun.lockb"))
    File.write(File.join(@temp_dir, "package-lock.json"), "")
    assert_equal "npm run test:run", adapter.resolve_test_cmd(@temp_dir)

    # Scenario E: only "test" script present
    File.write(File.join(@temp_dir, "package.json"), JSON.dump({ "scripts" => { "test" => "jest" } }))
    assert_equal "npm test", adapter.resolve_test_cmd(@temp_dir)

    # Scenario F: only "test:unit" script present
    File.write(File.join(@temp_dir, "package.json"), JSON.dump({ "scripts" => { "test:unit" => "mocha" } }))
    assert_equal "npm run test:unit", adapter.resolve_test_cmd(@temp_dir)

    # Scenario G: custom_test_cmd takes absolute precedence
    adapter.custom_test_cmd = "npx vitest run --coverage"
    assert_equal "npx vitest run --coverage", adapter.resolve_test_cmd(@temp_dir)
  end

  def test_node_adapter_check_syntax_command_generation
    adapter = Rubik::Adapter::NodeAdapter.new

    # We test using a spy / mock process runner to verify command construction
    ts_file = File.join(@temp_dir, "app.ts")
    vue_file = File.join(@temp_dir, "App.vue")
    js_file = File.join(@temp_dir, "index.js")

    commands_executed = []
    Rubik::Adapter::ProcessRunner.stub(:run, lambda { |cmd, **_opts|
      commands_executed << cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    }) do
      Rubik::Runtime::Discovery.stub(:binary_available?, true) do
        adapter.stub(:available?, true) do
          adapter.check_syntax(ts_file)
          adapter.check_syntax(vue_file)
          adapter.check_syntax(js_file)
        end
      end
    end

    assert_equal 3, commands_executed.size
    assert commands_executed[0].include?("tsc --noEmit")
    assert commands_executed[1].include?("vue-tsc --noEmit")
    assert commands_executed[2].include?("node --check")
  end

  def test_node_adapter_resolve_format_cmd
    adapter = Rubik::Adapter::NodeAdapter.new
    file = File.join(@temp_dir, "main.ts")

    format_cmd = adapter.resolve_format_cmd(file)
    assert format_cmd.include?("prettier --write") || format_cmd.include?("biome format --write")

    adapter.custom_format_cmd = "npx prettier --write %s"
    assert_equal "npx prettier --write #{Shellwords.escape(file)}", adapter.resolve_format_cmd(file)
  end

  def test_adapter_registry_contains_node_ts_js_vue
    registry = Rubik::Adapter::Registry.new

    assert_instance_of Rubik::Adapter::NodeAdapter, registry.get("node")
    assert_instance_of Rubik::Adapter::NodeAdapter, registry.get("javascript")
    assert_instance_of Rubik::Adapter::NodeAdapter, registry.get("typescript")
    assert_instance_of Rubik::Adapter::NodeAdapter, registry.get("vue")
  end

  # =========================================================================
  # 3. Discovery & Defaults
  # =========================================================================

  def test_discovery_candidates_and_defaults_for_vue
    assert_includes Rubik::Runtime::Discovery::LSP_CANDIDATES["vue"], "vue-language-server --stdio"
    assert_includes Rubik::Runtime::Discovery::FORMATTER_CANDIDATES["vue"], "prettier --write"
    assert_includes Rubik::Runtime::Discovery::FORMATTER_CANDIDATES["node"], "prettier --write"
    assert_equal "npm test", Rubik::Runtime::Discovery::DEFAULT_TEST_RUNNERS["vue"]

    assert_equal "vue-language-server --stdio", Rubik::Config::Defaults::DEFAULT_CONFIG.dig("lsp", "servers", "vue")

    defaults_lines = File.readlines(File.expand_path("../../lib/rubik/config/defaults.rb", __dir__)).size
    assert defaults_lines < 220, "defaults.rb must remain < 220 lines, currently #{defaults_lines}"
  end

  def test_detect_primary_language_recognizes_vue
    vue_dir = Dir.mktmpdir("rubik_vue_detect")
    begin
      File.write(File.join(vue_dir, "App.vue"), "<template><div>Hello</div></template>")
      detected = Rubik::Runtime::Discovery.detect_primary_language(vue_dir)
      assert_equal "vue", detected
    ensure
      FileUtils.remove_entry(vue_dir)
    end
  end

  # =========================================================================
  # 4. LSP Client, Manager, and JIT Buffer Sync
  # =========================================================================

  def test_lsp_client_servers_and_extension_map_contain_vue
    assert_equal "vue-language-server --stdio", Rubik::LSP::Client::SERVERS["vue"]
    assert_equal "vue", Rubik::LSP::Manager::EXTENSION_MAP[".vue"]
  end

  def test_lsp_manager_sync_buffer_file_if_needed
    lsp_mgr = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir)

    # When disabled, should return false
    @config.set("lsp.enabled", false)
    refute lsp_mgr.sync_buffer_file_if_needed("file.ts", @buffer_manager)

    @config.set("lsp.enabled", true)

    synced = []
    lsp_mgr.define_singleton_method(:sync_buffer_file) do |path, content|
      synced << [path, content]
      true
    end

    # Clean file not in buffer: no sync
    lsp_mgr.sync_buffer_file_if_needed("clean.ts", @buffer_manager)
    assert_empty synced

    # Dirty file in buffer: JIT sync triggered!
    @buffer_manager.write("dirty.ts", "const x: number = 42;")
    lsp_mgr.sync_buffer_file_if_needed("dirty.ts", @buffer_manager)

    assert_equal 1, synced.size
    assert_equal "dirty.ts", synced.first[0]
    assert_equal "const x: number = 42;", synced.first[1]
  end

  # =========================================================================
  # 5. LSP Tools JIT Sync & Elm-style Empathetic Diagnostics Tip
  # =========================================================================

  class MockLspManager
    attr_accessor :enabled, :sync_calls, :hover_response, :definition_response, :diagnostics_response

    def initialize
      @enabled = true
      @sync_calls = []
      @hover_response = { ok: true, result: {} }
      @definition_response = { ok: true, result: [] }
      @diagnostics_response = []
    end

    def enabled?
      @enabled
    end

    def sync_buffer_file_if_needed(path, buffer_mgr)
      @sync_calls << [path, buffer_mgr]
    end

    def hover(_path, _line, _char)
      @hover_response
    end

    def definition(_path, _line, _char)
      @definition_response
    end

    def diagnostics_for(_path)
      @diagnostics_response
    end

    def all_diagnostics
      {}
    end
  end

  def test_lsp_tools_initialization_and_effective_buffer_manager
    mock_lsp = MockLspManager.new
    tool = Rubik::Tools::LSPHoverTool.new(mock_lsp, buffer_manager: @buffer_manager)

    assert_equal @buffer_manager, tool.effective_buffer_manager

    # Positional arg backward compatibility
    tool_pos = Rubik::Tools::LSPHoverTool.new(mock_lsp, @buffer_manager)
    assert_equal @buffer_manager, tool_pos.effective_buffer_manager
  end

  def test_lsp_hover_jit_syncs_and_appends_elm_tip_on_dirty_buffer
    mock_lsp = MockLspManager.new
    tool = Rubik::Tools::LSPHoverTool.new(mock_lsp, buffer_manager: @buffer_manager)

    # Case 1: Clean file -> empty response -> no tip
    out_clean = tool.execute("file_path" => "test.ts", "line" => 1, "character" => 1)
    assert_includes out_clean, "No hover information available"
    refute_includes out_clean, "💡 Tip:"

    # Case 2: Dirty file in buffer -> empty response -> Elm-style tip appended!
    @buffer_manager.write("test.ts", "export const value = 123;")
    out_dirty = tool.execute("file_path" => "test.ts", "line" => 1, "character" => 1)

    assert_includes out_dirty, "No hover information available"
    assert_includes out_dirty, "💡 Tip: 'test.ts' has unapplied in-memory buffer modifications."
    assert_includes out_dirty, "Call 'apply_buffer' to persist changes to disk"

    # Verify JIT sync was triggered before query
    assert(mock_lsp.sync_calls.any? { |p, bm| p == "test.ts" && bm == @buffer_manager })
  end

  def test_lsp_definition_appends_elm_tip_on_dirty_buffer
    mock_lsp = MockLspManager.new
    tool = Rubik::Tools::LSPDefinitionTool.new(mock_lsp, buffer_manager: @buffer_manager)

    @buffer_manager.write("probe.ts", "function foo() {}")
    out = tool.execute("file_path" => "probe.ts", "line" => 1, "character" => 5)

    assert_includes out, "No definition found for symbol"
    assert_includes out, "💡 Tip: 'probe.ts' has unapplied in-memory buffer modifications."
  end

  def test_lsp_diagnostics_appends_elm_tip_on_dirty_buffer
    mock_lsp = MockLspManager.new
    tool = Rubik::Tools::LSPDiagnosticsTool.new(mock_lsp, buffer_manager: @buffer_manager)

    @buffer_manager.write("probe.ts", "function foo() {}")
    out = tool.execute("file_path" => "probe.ts")

    assert_includes out, "No LSP diagnostics or errors for 'probe.ts'."
    assert_includes out, "💡 Tip: 'probe.ts' has unapplied in-memory buffer modifications."
  end

  def test_registry_build_default_passes_buffer_manager_to_lsp_tools
    reg = Rubik::Tools::Registry.build_default(buffer_manager: @buffer_manager, root_dir: @temp_dir)

    hover_tool = reg.get("lsp_hover")
    assert_equal @buffer_manager, hover_tool.effective_buffer_manager

    diag_tool = reg.get("lsp_diagnostics")
    assert_equal @buffer_manager, diag_tool.effective_buffer_manager

    def_tool = reg.get("lsp_definition")
    assert_equal @buffer_manager, def_tool.effective_buffer_manager
  end

  # =========================================================================
  # 6. REPL !lsp Command: audience :both and dynamic start
  # =========================================================================

  def test_repl_lsp_command_registered_for_both_audiences
    output = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: output)

    meta = shell.commands["lsp"]
    assert meta, "Command !lsp must be registered"
    assert_equal :both, meta[:audience]

    # Test dynamic start usage text
    shell.execute_input("!lsp start")
    out_str = output.string
    assert_includes out_str, "Usage: !lsp start <"
    assert_includes out_str, "vue"
    assert_includes out_str, "typescript"
    assert_includes out_str, "ruby"
  end

  # =========================================================================
  # 7. REPL Shell Invariants: line count and tool event recording
  # =========================================================================

  def test_shell_line_count_within_strict_bounds
    shell_file = File.expand_path("../../lib/rubik/repl/shell.rb", __dir__)
    lines = File.readlines(shell_file).size
    assert lines <= 660, "shell.rb MUST be <= 660 lines to satisfy decoupling gate, got #{lines}"
    # Öneri 3 Kademe 1 moved the line-level input loop into lib/rubik/repl/input_loop.rb;
    # Kademe 2 moved with_output/capture_output/execute_command/execute_free_text into
    # lib/rubik/repl/input_execution.rb; Kademe 3 moved build_tool_registry/
    # orchestrator_loop/build_orchestrator_loop into lib/rubik/repl/setup_factories.rb;
    # Kademe 4 moved warm_ast_graph/stop_background_indexer/join_indexer_safely/
    # perform_warm_ast_graph into lib/rubik/repl/ast_warmup.rb (all included modules),
    # shrinking shell.rb well under the gate. The floor catches accidental truncation
    # of the class body (Lifecycle + InputLoop + InputExecution + SetupFactories +
    # AstWarmup extraction floor).
    assert lines >= 180, "shell.rb suspiciously small (#{lines}); Lifecycle/InputLoop/InputExecution/SetupFactories/AstWarmup extraction floor violated"
  end

  def test_shell_on_step_records_tool_call_and_result
    recorder_calls = []
    mock_recorder = Object.new
    mock_recorder.define_singleton_method(:record_tool_call) do |tool, args, call_id:|
      recorder_calls << [:call, tool, args, call_id]
    end
    mock_recorder.define_singleton_method(:record_tool_result) do |tool, output, status:, call_id:|
      recorder_calls << [:result, tool, output, status, call_id]
    end
    mock_recorder.define_singleton_method(:record) { |*| }
    mock_recorder.define_singleton_method(:record_user_turn) { |*| }
    mock_recorder.define_singleton_method(:record_assistant_response) { |*| }

    parts = Rubik::REPL::Composition.build(config: @config, buffer_manager: @buffer_manager, root_dir: @temp_dir)
    parts.recorder = mock_recorder

    output = StringIO.new
    shell = Rubik::REPL::Shell.new(parts: parts, output: output)

    # Extract on_step lambda by stubbing resolve_turn_route and orchestrator_loop
    dummy_route = { provider: Object.new, model: "test-model", context_limit: 4096, max_output_tokens: 1024 }
    shell.stub(:resolve_turn_route, dummy_route) do
      shell.stub(:orchestrator_loop, lambda { |**kwargs|
        on_step = kwargs[:on_step]
        on_step.call({ type: :tool_call, tool: "read_file", args: { "path" => "app.ts" }, call_id: "call_1" })
        on_step.call({ type: :tool_result, tool: "read_file", output: "export const x = 1;", status: :ok, call_id: "call_1" })

        # Mock orchestrator
        obj = Object.new
        obj.define_singleton_method(:run) { |_t, **_kw| { ok: true, output: "done" } }
        obj
      }) do
        shell.execute_input("inspect the file")
      end
    end

    assert_equal 2, recorder_calls.size
    assert_equal [:call, "read_file", { "path" => "app.ts" }, "call_1"], recorder_calls[0]
    assert_equal [:result, "read_file", "export const x = 1;", :ok, "call_1"], recorder_calls[1]
  end

  # =========================================================================
  # 8. ConfigWiring: Bidirectional Network / Sandbox Reactivity
  # =========================================================================

  def test_config_wiring_bidirectional_network_and_sandbox_sync
    output = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: output)

    # 1. Setting network.allow -> updates sandbox.allow_network
    @config.set("network.allow", true)
    assert_equal true, @config.fetch("sandbox.allow_network")

    # 2. Setting sandbox.allow_network -> updates network.allow
    @config.set("sandbox.allow_network", false)
    assert_equal false, @config.fetch("network.allow")

    # 3. Verify no recursion or infinite loop
    @config.set("network.allow", true)
    assert_equal true, @config.fetch("sandbox.allow_network")
    assert_equal true, @config.fetch("network.allow")

    # 4. Cleanups unroll cleanly
    shell.stop
    assert_empty shell.config_cleanups
  end
end
