# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/buffer/manager"
require "rubik/tools/builtins/lsp"

class TestLSPReferencesTool < Minitest::Test
  class FakeLSPManager
    attr_accessor :enabled, :references_response, :last_refs_args, :context

    def initialize(enabled: true, context: nil)
      @enabled = enabled
      @context = context
      @references_response = {
        ok: true,
        result: [
          { "uri" => "file:///app/lib/foo.rb", "range" => { "start" => { "line" => 9, "character" => 2 } } },
          { "uri" => "file:///app/lib/bar.rb", "range" => { "start" => { "line" => 19, "character" => 4 } } }
        ]
      }
      @last_refs_args = nil
    end

    def enabled?
      @enabled
    end

    def sync_buffer_file_if_needed(path, buffer_mgr); end

    def references(path, line, char)
      @last_refs_args = [path, line, char]
      @references_response
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_lsp_refs_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @manager = FakeLSPManager.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_coeffects_and_archetypes_declaration
    assert_equal [Rubik::Coeffects::LSP_MANAGER], Rubik::Tools::LSPReferencesTool::REQUIRES
    assert_includes Rubik::Tools::LSPReferencesTool::DECLARATION.archetypes, :research
    refute_includes Rubik::Tools::LSPReferencesTool::DECLARATION.archetypes, :coder
    refute_includes Rubik::Tools::LSPHoverTool::DECLARATION.archetypes, :coder
    refute_includes Rubik::Tools::LSPDefinitionTool::DECLARATION.archetypes, :coder
  end

  def test_references_manager_nil_or_disabled
    nil_tool = Rubik::Tools::LSPReferencesTool.new(nil)
    res_nil = nil_tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_nil, "LSP manager is not connected."

    disabled_manager = FakeLSPManager.new(enabled: false)
    disabled_tool = Rubik::Tools::LSPReferencesTool.new(disabled_manager)
    res_disabled = disabled_tool.execute("file_path" => "lib/app.rb", "line" => 1, "character" => 1)
    assert_includes res_disabled, "LSP is currently disabled"
  end

  def test_references_argument_validation
    tool = Rubik::Tools::LSPReferencesTool.new(@manager)

    res_no_path = tool.execute("file_path" => "", "line" => 1, "character" => 1)
    assert_includes res_no_path, "File path is required."

    res_bad_line = tool.execute("file_path" => "lib/app.rb", "line" => 0, "character" => 1)
    assert_includes res_bad_line, "Line number must be >= 1."
  end

  def test_references_coordinate_conversion
    tool = Rubik::Tools::LSPReferencesTool.new(@manager)

    tool.execute("file_path" => "lib/app.rb", "line" => 10, "character" => 5)
    assert_equal ["lib/app.rb", 9, 4], @manager.last_refs_args

    tool.execute("file_path" => "lib/app.rb", "line" => "3", "col" => "8")
    assert_equal ["lib/app.rb", 2, 7], @manager.last_refs_args
  end

  def test_references_formatting_and_windows_uri_handling
    tool = Rubik::Tools::LSPReferencesTool.new(@manager)

    @manager.references_response = {
      ok: true,
      result: [
        { "uri" => "file:///C:/project/app.rb", "range" => { "start" => { "line" => 14, "character" => 3 } } }
      ]
    }
    output = tool.execute("file_path" => "app.rb", "line" => 1, "character" => 1)
    assert_includes output, "Found 1 reference location(s):"
    refute_includes output, "/C:/project/app.rb", "Leading slash on drive letter must be stripped"
    assert_includes output, "C:/project/app.rb:15:4"
  end

  def test_references_empty_result_and_buffer_tip
    tool = Rubik::Tools::LSPReferencesTool.new(@manager, buffer_manager: @buffer_manager)
    @manager.references_response = { ok: true, result: [] }

    res_clean = tool.execute("file_path" => "lib/app.rb", "line" => 5, "character" => 5)
    assert_includes res_clean, "No references found for symbol at lib/app.rb:5:5"
    refute_includes res_clean, "💡 Tip:"

    @buffer_manager.write("lib/app.rb", "class App; end")
    res_dirty = tool.execute("file_path" => "lib/app.rb", "line" => 5, "character" => 5)
    assert_includes res_dirty, "No references found for symbol at lib/app.rb:5:5"
    assert_includes res_dirty, "💡 Tip: 'lib/app.rb' has unapplied in-memory buffer modifications."
  end
end
