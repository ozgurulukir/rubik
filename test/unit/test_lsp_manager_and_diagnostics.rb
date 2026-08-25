# frozen_string_literal: true

require_relative "../test_helper"
require "ostruct"

class TestLSPManagerAndDiagnostics < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @home_dir = Dir.mktmpdir
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir)
  end

  def teardown
    @manager.stop_all rescue nil
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

    client.send(:handle_incoming_message, mock_notification)

    diags = client.diagnostics_for("src/main.rs")
    assert_equal 2, diags.size
    assert_equal 1, diags.first["severity"]
    assert_includes diags.first["message"], "mismatched types"
  end

  def test_lsp_diagnostics_tool_output
    @config.set("lsp.enabled", true)
    client = Rubik::LSP::Client.new("go", root_dir: @temp_dir, server_cmd: "gopls")
    @manager.instance_variable_get(:@clients)["go"] = client
    client.instance_variable_set(:@running, true)

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
    client.send(:handle_incoming_message, mock_notification)

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

    # 2. Enabled & Clean
    @config.set("lsp.enabled", true)
    xml_clean = Rubik::Prompt::ContextBuilder.build_lsp_xml(@manager)
    assert_includes xml_clean, "<lsp_status enabled=\"true\""
    assert_includes xml_clean, "clean=\"true\""

    # 3. Enabled with Diagnostics
    client = Rubik::LSP::Client.new("rust", root_dir: @temp_dir, server_cmd: "rust-analyzer")
    @manager.instance_variable_get(:@clients)["rust"] = client
    client.instance_variable_set(:@running, true)

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
    client.send(:handle_incoming_message, mock_notification)

    xml_diags = Rubik::Prompt::ContextBuilder.build_lsp_xml(@manager)
    assert_includes xml_diags, "<lsp_diagnostics"
    assert_includes xml_diags, "<diagnostic file=\"#{@temp_dir}/src/lib.rs\" line=\"10\" severity=\"error\">"
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
    assert shell.instance_variable_get(:@lsp_manager).enabled?

    # 3. !lsp diag
    out.reopen
    shell.execute_input("!lsp diag")
    assert_includes out.string, "No active LSP diagnostics"

    # 4. !lsp off
    out.reopen
    shell.execute_input("!lsp off")
    assert_includes out.string, "LSP integration disabled"
    refute shell.instance_variable_get(:@lsp_manager).enabled?
  end

  def test_orchestrator_live_lsp_diagnostics_feedback_loop
    @config.set("lsp.enabled", true)
    @config.set("lsp.auto_diagnostics", true)

    client = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir, server_cmd: "solargraph")
    @manager.instance_variable_get(:@clients)["ruby"] = client
    client.instance_variable_set(:@running, true)

    # Inject a compilation error for app.rb
    mock_notification = {
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri" => "file://#{@temp_dir}/app.rb",
        "diagnostics" => [
          {
            "range" => { "start" => { "line" => 2, "character" => 4 } },
            "severity" => 1,
            "message" => "syntax error, unexpected `end`"
          }
        ]
      }
    }
    client.send(:handle_incoming_message, mock_notification)

    # Mock provider that calls write_file and then finishes
    mock_provider = Class.new do
      def complete(history, opts = {})
        step = history.count { |h| h[:role] == "assistant" }
        if step == 0
          Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
            "Writing broken file",
            true,
            [{ "tool" => "write_file", "args" => { "path" => "app.rb", "content" => "def foo\nend\nend\n" } }],
            nil
          )
        else
          Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
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
      shell: OpenStruct.new(lsp_manager: @manager, config: @config, buffer_manager: @buffer_manager, runtime_manager: nil, snapshot_store: nil, context_index: nil),
      on_step: ->(s) { steps_recorded << s }
    )

    res = orchestrator.run("Fix the syntax error")
    assert res[:ok]

    # Verify tool result contains the real-time LSP compiler diagnostic warning
    tool_result_step = steps_recorded.find { |s| s[:type] == :tool_result && s[:tool] == "write_file" }
    refute_nil tool_result_step
    assert_includes tool_result_step[:output], "LSP Real-Time Compiler Diagnostics - 1 error(s)"
    assert_includes tool_result_step[:output], "syntax error, unexpected `end`"
  end
end
