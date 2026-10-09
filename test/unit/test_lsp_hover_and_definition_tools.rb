# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/buffer/manager"
require "rubik/tools/builtins/lsp"

class TestLSPHoverAndDefinitionTools < Minitest::Test
  class FakeLSPManager
    attr_accessor :enabled, :hover_response, :definition_response, :last_hover_args, :last_def_args, :context

    def initialize(enabled: true, context: nil)
      @enabled = enabled
      @context = context
      @hover_response = { ok: true, result: { "contents" => "def test_symbol\nSome documentation" } }
      @definition_response = { ok: true, result: [{ "uri" => "file:///app/lib/foo.rb", "range" => { "start" => { "line" => 4, "character" => 2 } } }] }
      @last_hover_args = nil
      @last_def_args = nil
    end

    def enabled?
      @enabled
    end

    def sync_buffer_file_if_needed(path, buffer_mgr); end

    def hover(path, line, char)
      @last_hover_args = [path, line, char]
      @hover_response
    end

    def definition(path, line, char)
      @last_def_args = [path, line, char]
      @definition_response
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_lsp_tools_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @manager = FakeLSPManager.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  # =========================================================================
  # LSPHoverTool Tests
  # =========================================================================

  def test_hover_manager_nil_or_disabled
    nil_tool = Rubik::Tools::LSPHoverTool.new(nil)
    res_nil = nil_tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_nil, "LSP manager is not connected."

    disabled_manager = FakeLSPManager.new(enabled: false)
    disabled_tool = Rubik::Tools::LSPHoverTool.new(disabled_manager)
    res_disabled = disabled_tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_disabled, "LSP is currently disabled"
  end

  def test_hover_validation_errors
    tool = Rubik::Tools::LSPHoverTool.new(@manager)

    res_no_path = tool.execute("file_path" => "", "line" => 1, "character" => 1)
    assert_includes res_no_path, "File path is required."

    res_bad_line = tool.execute("file_path" => "lib/app.rb", "line" => 0, "character" => 1)
    assert_includes res_bad_line, "Line number must be >= 1."
  end

  def test_hover_coordinate_conversion_and_parameter_aliases
    tool = Rubik::Tools::LSPHoverTool.new(@manager)

    tool.execute("file_path" => "lib/app.rb", "line" => 10, "character" => 5)
    assert_equal ["lib/app.rb", 9, 4], @manager.last_hover_args

    # Parameter alias 'col'
    tool.execute("file_path" => "lib/app.rb", "line" => "3", "col" => "8")
    assert_equal ["lib/app.rb", 2, 7], @manager.last_hover_args

    # Clamping character < 1
    tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 0)
    assert_equal ["lib/app.rb", 0, 0], @manager.last_hover_args
  end

  def test_hover_response_contents_formats
    tool = Rubik::Tools::LSPHoverTool.new(@manager)

    # 1. Hash format {"value" => ...}
    @manager.hover_response = { ok: true, result: { "contents" => { "kind" => "markdown", "value" => "def foo\nDocstring" } } }
    res_hash = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_equal "def foo\nDocstring", res_hash

    # 2. Array format
    @manager.hover_response = { ok: true, result: { "contents" => [{ "value" => "type Foo" }, "extra docstring"] } }
    res_arr = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_equal "type Foo\nextra docstring", res_arr

    # 3. Scalar string format
    @manager.hover_response = { ok: true, result: { "contents" => "String description" } }
    res_str = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_equal "String description", res_str
  end

  def test_hover_empty_contents_and_dirty_buffer_tip
    tool = Rubik::Tools::LSPHoverTool.new(@manager, buffer_manager: @buffer_manager)
    @manager.hover_response = { ok: true, result: { "contents" => nil } }

    # Clean file: no tip
    res_clean = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_clean, "No hover information available at lib/app.rb:1:1"
    refute_includes res_clean, "💡 Tip:"

    # Dirty file in buffer: tip appended
    @buffer_manager.write("lib/app.rb", "class App; end")
    res_dirty = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_dirty, "No hover information available at lib/app.rb:1:1"
    assert_includes res_dirty, "💡 Tip: 'lib/app.rb' has unapplied in-memory buffer modifications."
  end

  def test_hover_lsp_error_response
    tool = Rubik::Tools::LSPHoverTool.new(@manager)
    @manager.hover_response = { ok: false, error: "Method not supported" }

    res_err = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_err, "LSP Hover failed: Method not supported"
  end

  # =========================================================================
  # LSPDefinitionTool Tests
  # =========================================================================

  def test_definition_manager_nil_or_disabled
    nil_tool = Rubik::Tools::LSPDefinitionTool.new(nil)
    res_nil = nil_tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_nil, "LSP manager is not connected."

    disabled_manager = FakeLSPManager.new(enabled: false)
    disabled_tool = Rubik::Tools::LSPDefinitionTool.new(disabled_manager)
    res_disabled = disabled_tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_disabled, "LSP is currently disabled"
  end

  def test_definition_validation_errors
    tool = Rubik::Tools::LSPDefinitionTool.new(@manager)

    res_no_path = tool.execute("file_path" => "", "line" => 1, "character" => 1)
    assert_includes res_no_path, "File path is required."

    res_bad_line = tool.execute("file_path" => "lib/app.rb", "line" => -1, "character" => 1)
    assert_includes res_bad_line, "Line number must be >= 1."
  end

  def test_definition_coordinate_conversion_and_parameter_aliases
    tool = Rubik::Tools::LSPDefinitionTool.new(@manager)

    tool.execute("file_path" => "lib/app.rb", "line" => 15, "col" => 8)
    assert_equal ["lib/app.rb", 14, 7], @manager.last_def_args
  end

  def test_definition_single_and_multiple_locations
    tool = Rubik::Tools::LSPDefinitionTool.new(@manager)

    # Single location
    @manager.definition_response = {
      ok: true,
      result: [
        { "uri" => "file:///app/lib/foo.rb", "range" => { "start" => { "line" => 9, "character" => 2 } } }
      ]
    }
    res_single = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_single, "Found 1 definition location(s):"
    assert_includes res_single, "• /app/lib/foo.rb:10:3"

    # Multiple locations
    @manager.definition_response = {
      ok: true,
      result: [
        { "uri" => "file:///app/lib/foo.rb", "range" => { "start" => { "line" => 9, "character" => 2 } } },
        { "uri" => "file:///app/lib/bar.rb", "range" => { "start" => { "line" => 19, "character" => 4 } } }
      ]
    }
    res_multi = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_multi, "Found 2 definition location(s):"
    assert_includes res_multi, "• /app/lib/foo.rb:10:3"
    assert_includes res_multi, "• /app/lib/bar.rb:20:5"
  end

  def test_definition_target_uri_and_target_selection_range_format
    tool = Rubik::Tools::LSPDefinitionTool.new(@manager)

    @manager.definition_response = {
      ok: true,
      result: [
        {
          "targetUri" => "file:///app/lib/target.rb",
          "targetSelectionRange" => { "start" => { "line" => 49, "character" => 11 } }
        }
      ]
    }
    res_target = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_target, "Found 1 definition location(s):"
    assert_includes res_target, "• /app/lib/target.rb:50:12"
  end

  def test_definition_empty_result_and_dirty_buffer_tip
    tool = Rubik::Tools::LSPDefinitionTool.new(@manager, buffer_manager: @buffer_manager)
    @manager.definition_response = { ok: true, result: [] }

    # Clean file: no tip
    res_clean = tool.execute("file_path" => "lib/app.rb", "line" => 5, "character" => 5)
    assert_includes res_clean, "No definition found for symbol at lib/app.rb:5:5"
    refute_includes res_clean, "💡 Tip:"

    # Dirty file in buffer: tip appended
    @buffer_manager.write("lib/app.rb", "class App; end")
    res_dirty = tool.execute("file_path" => "lib/app.rb", "line" => 5, "character" => 5)
    assert_includes res_dirty, "No definition found for symbol at lib/app.rb:5:5"
    assert_includes res_dirty, "💡 Tip: 'lib/app.rb' has unapplied in-memory buffer modifications."
  end

  def test_definition_lsp_error_response
    tool = Rubik::Tools::LSPDefinitionTool.new(@manager)
    @manager.definition_response = { ok: false, error: "Server timeout" }

    res_err = tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_err, "LSP Definition failed: Server timeout"
  end
end
