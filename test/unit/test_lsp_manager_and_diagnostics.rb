# frozen_string_literal: true

require_relative "../test_helper"

class TestLSPManagerAndDiagnostics < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @home_dir = Dir.mktmpdir
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    # LSP feedback-loop mechanics, not the maestro doctrine (its own suite:
    # test_maestro_gate.rb) - the scripted root agent writes directly.
    @config.set("subagents.maestro_gate", false)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir)
  end

  def teardown
    begin
      @manager.stop_all
    rescue
      nil
    end
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@home_dir)
  end

  def test_lsp_config_defaults_and_toggling
    assert @manager.enabled?, "LSP should be enabled by default with dynamic discovery"
    assert @manager.auto_diagnostics?, "auto_diagnostics should default to true"

    @config.set("lsp.enabled", false)
    refute @manager.enabled?

    @config.set("lsp.enabled", true)
    assert @manager.enabled?

    @config.set("lsp.auto_diagnostics", false)
    refute @manager.auto_diagnostics?
  end

  def test_detect_language_by_extension
    assert_equal "go", @manager.detect_language("main.go")
    assert_equal "rust", @manager.detect_language("src/lib.rs")
    assert_equal "zig", @manager.detect_language("main.zig")
    assert_equal "c", @manager.detect_language("engine.c")
    assert_equal "c", @manager.detect_language("header.h")
    assert_equal "python", @manager.detect_language("script.py")
    assert_equal "ruby", @manager.detect_language("lib/app.rb")
    assert_nil @manager.detect_language("README.md")
  end

  # Justified white-box stimulus (kept): textDocument/publishDiagnostics is a
  # wire notification whose only production caller is the private reader
  # thread; without a spawned server, injecting it through the private
  # handler is the only way to reach the diagnostics pipeline the assertions
  # observe (diagnostics_for / snapshot / XML projection).
  def deliver_notification(client, notification)
    client.send(:handle_incoming_message, notification)
  end

  def test_client_mock_diagnostics_handling
    client = Rubik::LSP::Client.new("rust", root_dir: @temp_dir, server_cmd: "rust-analyzer")

    # Simulate receiving textDocument/publishDiagnostics notification
    mock_notification = {
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri" => "file://#{@temp_dir}/src/main.rs",
        "diagnostics" => [
          {
            "range" => { "start" => { "line" => 41, "character" => 10 }, "end" => { "line" => 41, "character" => 20 } },
            "severity" => 1,
            "message" => "mismatched types: expected `String`, found `&str`"
          },
          {
            "range" => { "start" => { "line" => 12, "character" => 4 }, "end" => { "line" => 12, "character" => 15 } },
            "severity" => 2,
            "message" => "unused variable: `x`"
          }
        ]
      }
    }

    deliver_notification(client, mock_notification)

    diags = client.diagnostics_for("src/main.rs")
    assert_equal 2, diags.size
    assert_equal 1, diags.first["severity"]
    assert_includes diags.first["message"], "mismatched types"
  end

  def test_lsp_diagnostics_tool_output
    @config.set("lsp.enabled", true)
    client = Rubik::LSP::Client.new("go", root_dir: @temp_dir, server_cmd: "gopls")
    @manager.clients["go"] = client
    fake_connected_lsp_client!(client)

    # Add mock diagnostic
    mock_notification = {
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri" => "file://#{@temp_dir}/main.go",
        "diagnostics" => [
          {
            "range" => { "start" => { "line" => 14, "character" => 2 } },
            "severity" => 1,
            "message" => "undefined: fmt.Printl"
          }
        ]
      }
    }
    deliver_notification(client, mock_notification)

    tool = Rubik::Tools::LSPDiagnosticsTool.new(@manager)

    # Query specific file
    file_output = tool.execute("file_path" => "main.go")
    assert_includes file_output, "=== LSP Diagnostics for main.go"
    assert_includes file_output, "[ERROR] Line 15:3 - undefined: fmt.Printl"

    # Query all workspace
    all_output = tool.execute({})
    assert_includes all_output, "Active Workspace LSP Diagnostics"
    assert_includes all_output, "main.go"
  end

  def test_lsp_hover_and_definition_tools_disabled_and_validation
    tool_hover = Rubik::Tools::LSPHoverTool.new(@manager)
    tool_def = Rubik::Tools::LSPDefinitionTool.new(@manager)

    # When disabled
    @config.set("lsp.enabled", false)
    res1 = tool_hover.execute("file_path" => "main.go", "line" => 10, "character" => 5)
    assert_includes res1, "LSP is currently disabled"

    @config.set("lsp.enabled", true)
    res_val = tool_hover.execute("file_path" => "", "line" => 10, "character" => 5)
    assert_includes res_val, "File path is required"

    res_line = tool_hover.execute("file_path" => "main.go", "line" => 0, "character" => 5)
    assert_includes res_line, "Line number must be >= 1"

    res_def = tool_def.execute("file_path" => "main.unknown_lang", "line" => 10, "character" => 5)
    assert_includes res_def, "LSP not active"
  end

  def test_context_builder_lsp_xml
    # 1. Disabled -> empty
    @config.set("lsp.enabled", false)
    xml_disabled = Rubik::Prompt::ContextBuilder.build_lsp_xml(@manager)
    assert_empty xml_disabled

    # 2. Enabled but NO server connected -> honest no_servers state (session
    # review B2: this used to render clean="true", reading as "all good"
    # while every LSP tool was dead).
    @config.set("lsp.enabled", true)
    xml_no_servers = Rubik::Prompt::ContextBuilder.build_lsp_xml(@manager)
    assert_includes xml_no_servers, "<lsp_status enabled=\"true\""
    assert_includes xml_no_servers, "state=\"no_servers\""
    refute_includes xml_no_servers, "clean=\"true\""
    assert_includes xml_no_servers, "NO language server is connected"

    # 2b. Enabled, a server running, zero diagnostics -> the real clean state.
    idle_client = Rubik::LSP::Client.new("go", root_dir: @temp_dir, server_cmd: "gopls")
    @manager.clients["go"] = idle_client
    fake_connected_lsp_client!(idle_client)
    xml_clean = Rubik::Prompt::ContextBuilder.build_lsp_xml(@manager)
    assert_includes xml_clean, "active_servers=\"go\""
    assert_includes xml_clean, "clean=\"true\""

    # 3. Enabled with Diagnostics
    client = Rubik::LSP::Client.new("rust", root_dir: @temp_dir, server_cmd: "rust-analyzer")
    @manager.clients["rust"] = client
    fake_connected_lsp_client!(client)

    mock_notification = {
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri" => "file://#{@temp_dir}/src/lib.rs",
        "diagnostics" => [
          {
            "range" => { "start" => { "line" => 9, "character" => 1 } },
            "severity" => 1,
            "message" => "cannot find value `foo` in this scope"
          }
        ]
      }
    }
    deliver_notification(client, mock_notification)

    xml_diags = Rubik::Prompt::ContextBuilder.build_lsp_xml(@manager)
    expected_file = Rubik::Platform.normalize_path("#{@temp_dir}/src/lib.rs")
    assert_includes xml_diags, "<lsp_diagnostics"
    assert_includes xml_diags, "<diagnostic file=\"#{expected_file}\" line=\"10\" severity=\"error\">"
    assert_includes xml_diags, "cannot find value `foo` in this scope"
  end

  def test_repl_lsp_commands
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)

    # 1. !lsp status
    shell.execute_input("!lsp status")
    assert_includes out.string, "=== LSP Integration Status ==="
    assert_includes out.string, "Enabled          : true"

    # 2. !lsp on
    out.reopen
    shell.execute_input("!lsp on")
    assert_includes out.string, "LSP integration enabled"
    assert shell.lsp_manager.enabled?

    # 3. !lsp diag
    out.reopen
    shell.execute_input("!lsp diag")
    assert_includes out.string, "No active LSP diagnostics"

    # 4. !lsp off
    out.reopen
    shell.execute_input("!lsp off")
    assert_includes out.string, "LSP integration disabled"
    refute shell.lsp_manager.enabled?
  end

  def test_orchestrator_live_lsp_diagnostics_feedback_loop
    @config.set("lsp.enabled", true)
    @config.set("lsp.auto_diagnostics", true)

    client = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir, server_cmd: "solargraph")
    @manager.clients["ruby"] = client
    # Full sync capabilities: the feedback loop drives sync_buffer_file →
    # did_open; the didOpen transport write itself is intercepted below.
    fake_connected_lsp_client!(client, sync: :full)

    # Publish a versioned compiler result after didOpen reaches the fake server.
    publisher_thread = nil
    client.define_singleton_method(:send_notification) do |method, params|
      if method == "textDocument/didOpen"
        document = params[:textDocument]
        publisher_thread = Thread.new do
          # Justified white-box stimulus (kept): see deliver_notification.
          client.send(:handle_incoming_message, {
                        "method" => "textDocument/publishDiagnostics",
                        "params" => {
                          "uri" => document[:uri],
                          "version" => document[:version],
                          "diagnostics" => [{
                            "range" => { "start" => { "line" => 2, "character" => 4 } },
                            "severity" => 1,
                            "message" => "syntax error, unexpected `end`"
                          }]
                        }
                      })
        end
      end
      true
    end

    # Mock provider that calls write_file and then finishes
    mock_provider = Class.new do
      def complete(history, _opts = {})
        step = history.count { |h| h[:role] == "assistant" }
        if step.zero?
          Struct.new(:text, :tool_calls?, :tool_calls, :usage).new(
            "Writing broken file",
            true,
            [{ "tool" => "write_file", "args" => { "path" => "app.rb", "content" => "def foo\nend\nend\n" } }],
            nil
          )
        else
          Struct.new(:text, :tool_calls?, :tool_calls, :usage).new(
            "Finished fixing",
            false,
            [],
            nil
          )
        end
      end
    end.new

    tool_reg = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      lsp_manager: @manager,
      root_dir: @temp_dir
    )

    steps_recorded = []
    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: tool_reg,
      shell: Struct.new(:lsp_manager, :config, :buffer_manager, :runtime_manager, :snapshot_store, :context_index)
                   .new(@manager, @config, @buffer_manager, nil, nil, nil),
      on_step: ->(s) { steps_recorded << s }
    )

    res = orchestrator.run("Fix the syntax error")
    publisher_thread&.join
    assert res[:ok]

    # Verify tool result contains the real-time LSP compiler diagnostic warning
    tool_result_step = steps_recorded.find { |s| s[:type] == :tool_result && s[:tool] == "write_file" }
    refute_nil tool_result_step
    assert_includes tool_result_step[:output], "LSP Real-Time Compiler Diagnostics - 1 error(s)"
    assert_includes tool_result_step[:output], "syntax error, unexpected `end`"
  end

  def test_did_change_marks_cached_diagnostics_pending_until_replaced
    client = Rubik::LSP::Client.new("rust", root_dir: @temp_dir, server_cmd: "rust-analyzer")
    fake_connected_lsp_client!(client, sync: :full)
    client.stub(:send_notification, true) do
      assert client.did_open("src/main.rs", "fn main() {}")
    end
    deliver_notification(client, {
                           "method" => "textDocument/publishDiagnostics",
                           "params" => {
                             "uri" => "file://#{@temp_dir}/src/main.rs",
                             "version" => 1,
                             "diagnostics" => [{ "severity" => 1, "message" => "compiler error" }]
                           }
                         })
    assert_equal :fresh, client.diagnostics_snapshot_for("src/main.rs")[:state]

    client.stub(:send_notification, true) do
      client.did_change("src/main.rs", "fn main() { println!(); }")
    end

    snapshot = client.diagnostics_snapshot_for("src/main.rs")
    assert_equal :pending, snapshot[:state]
    assert_equal 1, snapshot[:diagnostics].size, "last known results remain available but are marked stale"
  end

  def test_lsp_hover_tool_execution
    @config.set("lsp.enabled", true)
    client = Rubik::LSP::Client.new("rust", root_dir: @temp_dir, server_cmd: "rust-analyzer")
    @manager.clients["rust"] = client
    fake_connected_lsp_client!(client)

    tool = Rubik::Tools::LSPHoverTool.new(@manager, @buffer_manager)

    # 1. Hash contents ({ "value" => "..." }) & 1-based to 0-based param check with "col" alias
    requested_args = nil
    client.stub(:hover, lambda { |path, line, char|
      requested_args = [path, line, char]
      { ok: true, result: { "contents" => { "value" => "fn calculate(x: i32) -> i32" } } }
    }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 10, "col" => 5)
      assert_equal "fn calculate(x: i32) -> i32", out
      assert_equal ["src/main.rs", 9, 4], requested_args
    end

    # 2. Array contents
    client.stub(:hover, { ok: true, result: { "contents" => [{ "value" => "struct User" }, "User struct docs"] } }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 1, "character" => 1)
      assert_equal "struct User\nUser struct docs", out
    end

    # 3. Plain String contents
    client.stub(:hover, { ok: true, result: { "contents" => "simple hover text" } }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 1, "character" => 1)
      assert_equal "simple hover text", out
    end

    # 4. Empty contents (clean buffer)
    client.stub(:hover, { ok: true, result: { "contents" => nil } }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 10, "character" => 5)
      assert_equal "No hover information available at src/main.rs:10:5", out
    end

    # 5. Empty contents (dirty buffer tip)
    @buffer_manager.write("src/main.rs", "fn main() { dirty }")
    client.stub(:hover, { ok: true, result: { "contents" => "" } }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 10, "character" => 5)
      assert_includes out, "No hover information available at src/main.rs:10:5"
      assert_includes out, "Tip: 'src/main.rs' has unapplied in-memory buffer modifications"
    end

    # 6. Hover failure
    client.stub(:hover, { ok: false, error: "Server timeout" }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 10, "character" => 5)
      assert_includes out, "LSP Hover failed: Server timeout"
    end
  end

  def test_lsp_definition_tool_execution
    @config.set("lsp.enabled", true)
    client = Rubik::LSP::Client.new("rust", root_dir: @temp_dir, server_cmd: "rust-analyzer")
    @manager.clients["rust"] = client
    fake_connected_lsp_client!(client)

    tool = Rubik::Tools::LSPDefinitionTool.new(@manager, @buffer_manager)

    # 1. Single definition location with standard uri and range
    client.stub(:definition, {
                  ok: true,
                  result: {
                    "uri" => "file:///workspace/src/lib.rs",
                    "range" => { "start" => { "line" => 15, "character" => 3 } }
                  }
                }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 5, "character" => 10)
      assert_includes out, "Found 1 definition location(s):"
      assert_includes out, "/workspace/src/lib.rs:16:4"
    end

    # 2. Multiple definition locations using targetUri and targetSelectionRange
    client.stub(:definition, {
                  ok: true,
                  result: [
                    {
                      "targetUri" => "file:///workspace/src/foo.rs",
                      "targetSelectionRange" => { "start" => { "line" => 0, "character" => 0 } }
                    },
                    {
                      "uri" => "file:///workspace/src/bar.rs",
                      "range" => { "start" => { "line" => 9, "character" => 4 } }
                    }
                  ]
                }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 5, "character" => 10)
      assert_includes out, "Found 2 definition location(s):"
      assert_includes out, "/workspace/src/foo.rs:1:1"
      assert_includes out, "/workspace/src/bar.rs:10:5"
    end

    # 3. No definition found (clean buffer)
    client.stub(:definition, { ok: true, result: [] }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 5, "character" => 10)
      assert_equal "No definition found for symbol at src/main.rs:5:10", out
    end

    # 4. No definition found (dirty buffer tip)
    @buffer_manager.write("src/main.rs", "fn main() { dirty }")
    client.stub(:definition, { ok: true, result: nil }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 5, "character" => 10)
      assert_includes out, "No definition found for symbol at src/main.rs:5:10"
      assert_includes out, "Tip: 'src/main.rs' has unapplied in-memory buffer modifications"
    end

    # 5. Definition call failure
    client.stub(:definition, { ok: false, error: "Language server crashed" }) do
      out = tool.execute("file_path" => "src/main.rs", "line" => 5, "character" => 10)
      assert_includes out, "LSP Definition failed: Language server crashed"
    end
  end

  # The two register_client_unlocked send() calls below are justified
  # white-box stimulus (kept): there is no public path that registers a
  # pre-built client into the coeffect context without spawning a real
  # language server — start_client only registers after a real handshake —
  # so the revertible-registration contract under test is otherwise
  # unreachable. The running flags are simulated through the public reader
  # (the same duck-typed double pattern as the alive? override below).
  def test_lsp_coeffect_lifecycle_and_revertible_disposable_re_registration
    ctx = Rubik::Runtime::Context.new
    manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir, context: ctx)

    client1 = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir, server_cmd: "solargraph")
    client1.define_singleton_method(:running) { true }
    manager.clients["ruby"] = client1
    manager.send(:register_client_unlocked, "ruby", client1)

    assert_equal client1, ctx.get("lsp:ruby"), "lsp:ruby should be provided in context"
    disposable_langs = manager.registered_disposable_langs
    assert_equal ctx.object_id, disposable_langs["ruby"], "registered_disposable_langs should track context object_id"

    # Stop client
    manager.stop_client("ruby")

    assert_nil ctx.get("lsp:ruby"), "stop_client should retract lsp:ruby coeffect"
    refute disposable_langs.key?("ruby"), "stop_client should clear registered_disposable_langs entry"

    # Restart client in same context
    client2 = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir, server_cmd: "solargraph")
    client2.define_singleton_method(:running) { true }

    stopped_on_dispose = false
    client2.define_singleton_method(:stop) { stopped_on_dispose = true }

    manager.clients["ruby"] = client2
    manager.send(:register_client_unlocked, "ruby", client2)

    assert_equal client2, ctx.get("lsp:ruby"), "lsp:ruby should be re-provided after restart"
    assert_equal ctx.object_id, disposable_langs["ruby"], "registered_disposable_langs should be set again"

    # Dispose context -> must stop client2
    ctx.dispose
    assert stopped_on_dispose, "Disposing context after LSP restart must stop the active LSP server"
  end

  def test_dead_client_removal_unprovides_coeffect_and_clears_disposable_tracking
    @config.set("lsp.auto_start", false)
    ctx = Rubik::Runtime::Context.new
    manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir, context: ctx)

    dead_client = Rubik::LSP::Client.new("python", root_dir: @temp_dir, server_cmd: "pyright")
    dead_client.define_singleton_method(:running) { true }
    dead_client.define_singleton_method(:alive?) { false }

    manager.clients["python"] = dead_client
    manager.send(:register_client_unlocked, "python", dead_client)

    assert_equal dead_client, ctx.get("lsp:python")
    disposable_langs = manager.registered_disposable_langs
    assert_equal ctx.object_id, disposable_langs["python"]

    # Public client_for path detects the dead client and cleans it up
    manager.client_for("python")

    assert_nil ctx.get("lsp:python"), "Dead client detection must unprovide lsp:python coeffect"
    refute disposable_langs.key?("python"), "Dead client detection must clear registered_disposable_langs tracking"
  end
end
