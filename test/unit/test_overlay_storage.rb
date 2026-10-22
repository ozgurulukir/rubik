# frozen_string_literal: true

require_relative "../test_helper"

class TestOverlayStorage < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_overlay_test")
    @overlay = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir, home_dir: @temp_dir)
  end

  def teardown
    remove_temp_dir(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_directory_structure
    assert File.directory?(@overlay.project_commands_dir)
    assert File.directory?(@overlay.global_commands_dir)
    assert File.directory?(@overlay.project_tools_dir)
    assert File.directory?(@overlay.global_tools_dir)
  end

  def test_save_and_delete_command
    res = @overlay.save_command("hello", '->(args, out, shell) { out.puts "hello" }', description: "Test command")
    assert res[:ok]
    assert_equal "hello", res[:name]
    assert File.exist?(res[:path])

    commands = @overlay.list_commands
    cmd_meta = commands.find { |c| c[:name] == "hello" }
    refute_nil cmd_meta
    assert_equal :verified, cmd_meta[:integrity]

    del_res = @overlay.delete_command("hello")
    assert del_res[:ok]
    refute File.exist?(res[:path])
  end

  def test_save_and_delete_tool
    res = @overlay.save_tool("my_tool", "->(args) { 'tool_out' }", description: "Test tool")
    assert res[:ok]
    assert_equal "my_tool", res[:name]
    assert File.exist?(res[:path])

    tools = @overlay.list_tools
    t_meta = tools.find { |t| t[:name] == "my_tool" }
    refute_nil t_meta
    assert_equal :verified, t_meta[:integrity]

    del_res = @overlay.delete_tool("my_tool")
    assert del_res[:ok]
    refute File.exist?(res[:path])
  end

  def test_path_traversal_blocked_in_record_hash
    target_dir = @overlay.project_commands_dir
    assert_raises(ArgumentError) do
      @overlay.record_hash(target_dir, "../../outside.rb", :project)
    end
  end

  def test_path_traversal_blocked_in_verify_integrity
    target_dir = @overlay.project_commands_dir
    outside_file = File.join(@temp_dir, "outside.rb")
    File.write(outside_file, "# Rubik Custom Command: !outside\n")

    verdict = @overlay.verify_integrity(outside_file, target_dir)
    assert_equal :rejected, verdict
  end

  def test_invalid_overlay_directory_rejected
    invalid_dir = File.expand_path(File.join(@temp_dir, "invalid_dir"))
    FileUtils.mkdir_p(invalid_dir)

    assert_raises(ArgumentError) do
      @overlay.manifest_path(invalid_dir)
    end

    assert_raises(ArgumentError) do
      @overlay.record_hash(invalid_dir, "test.rb", :project)
    end
  end

  def test_manifest_integrity_check_failure_rejects_modified_file
    res = @overlay.save_command("tampered", '->(args, out, shell) { "orig" }')
    assert res[:ok]

    # Modify file after manifest was recorded
    File.write(res[:path], "# modified content")

    commands = @overlay.list_commands
    cmd_meta = commands.find { |c| c[:name] == "tampered" }
    refute_nil cmd_meta
    assert_equal :rejected, cmd_meta[:integrity]
  end
end
