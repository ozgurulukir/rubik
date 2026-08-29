# frozen_string_literal: true

require_relative "../test_helper"

# Regression tests for the pasted-session findings: list_files/grep path
# filters silently failing on absolute paths, and the finish path double
# printing the final answer.
class TestPathFilterNormalization < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@temp_dir, "lib"))
    File.write(File.join(@temp_dir, "lib", "greeter.rb"), "class Greeter; end\n")
    File.write(File.join(@temp_dir, "readme.md"), "hi\n")

    @index = Rubik::Context::Index.new(root_dir: @temp_dir, native: "off")
    @index.full_scan
    @buffer = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_list_files_accepts_absolute_path_under_root
    tool = Rubik::Tools::ListFilesTool.new(@index, root_dir: @temp_dir)
    res = tool.execute({ "path" => File.join(@temp_dir, "lib") })
    assert_includes res, "lib/greeter.rb"
  end

  def test_list_files_accepts_backslash_absolute_path
    tool = Rubik::Tools::ListFilesTool.new(@index, root_dir: @temp_dir)
    res = tool.execute({ "path" => "#{@temp_dir.tr("/", "\\")}\\lib" })
    assert_includes res, "lib/greeter.rb"
  end

  def test_list_files_root_itself_lists_everything
    tool = Rubik::Tools::ListFilesTool.new(@index, root_dir: @temp_dir)
    res = tool.execute({ "path" => @temp_dir })
    assert_includes res, "lib/greeter.rb"
    assert_includes res, "readme.md"
  end

  def test_list_files_path_outside_root_is_a_helpful_error
    tool = Rubik::Tools::ListFilesTool.new(@index, root_dir: @temp_dir)
    res = tool.execute({ "path" => "C:/elsewhere/project" })
    assert_includes res, "outside the project workspace"
    assert_includes res, "relative to the project root"
  end

  def test_list_files_no_match_hints_relative_paths
    tool = Rubik::Tools::ListFilesTool.new(@index, root_dir: @temp_dir)
    res = tool.execute({ "path" => "nope" })
    assert_includes res, "No matching files found for 'nope'"
    assert_includes res, "relative to the project root"
  end

  def test_grep_accepts_absolute_path_filter
    tool = Rubik::Tools::GrepSearchTool.new(@buffer, @index, root_dir: @temp_dir, config: NativeOffConfig2.new)
    res = tool.execute({ "query" => "Greeter", "path" => File.join(@temp_dir, "lib") })
    assert_includes res, "lib/greeter.rb:1:"
  end

  def test_grep_path_outside_root_is_a_helpful_error
    tool = Rubik::Tools::GrepSearchTool.new(@buffer, @index, root_dir: @temp_dir, config: NativeOffConfig2.new)
    res = tool.execute({ "query" => "Greeter", "path" => "C:/elsewhere/other" })
    assert_includes res, "outside the project workspace"
  end

  def test_normalize_path_filter_cases
    root = "C:/work/proj"
    assert_equal ["", nil], Rubik::Tools::BaseTool.normalize_path_filter("", root)
    assert_equal ["", nil], Rubik::Tools::BaseTool.normalize_path_filter(".", root)
    assert_equal ["lib", nil], Rubik::Tools::BaseTool.normalize_path_filter("./lib", root)
    assert_equal ["lib/sub", nil], Rubik::Tools::BaseTool.normalize_path_filter("C:/work/proj/lib/sub", root)
    assert_equal ["lib/sub", nil], Rubik::Tools::BaseTool.normalize_path_filter("C:\\work\\proj\\lib\\sub", root)
    filter, error = Rubik::Tools::BaseTool.normalize_path_filter("C:/elsewhere", root)
    assert_nil filter
    assert_includes error, "outside the project workspace"
  end
end

class NativeOffConfig2
  def fetch(_key, _default = nil)
    "off"
  end
end
