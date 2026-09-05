# frozen_string_literal: true

require_relative "../test_helper"

class TestBufferApplyConflict < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_conflict_test")
    @event_bus = Rubik::EventBus.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_apply_detects_conflict_and_skips_by_default
    file_path = File.join(@temp_dir, "test.txt")
    File.write(file_path, "initial content\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.read("test.txt")
    manager.write("test.txt", "buffered content\n")

    # External process modifies the file on disk
    File.write(file_path, "external modified content\n")

    applied = manager.apply!

    assert_empty applied
    assert_equal ["test.txt"], manager.last_conflicts
    assert manager.dirty?("test.txt")
    assert_equal "external modified content\n", File.read(file_path)
    assert_equal "buffered content\n", manager.read("test.txt")
  end

  def test_apply_conflict_with_overwrite_policy
    file_path = File.join(@temp_dir, "test.txt")
    File.write(file_path, "initial content\n")

    config = { "buffer" => { "on_external_modification" => "overwrite" } }
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, config: config, event_bus: @event_bus)
    manager.read("test.txt")
    manager.write("test.txt", "buffered content\n")

    # External modification
    File.write(file_path, "external modified content\n")

    applied = manager.apply!

    assert_equal ["test.txt"], applied
    assert_empty manager.last_conflicts
    refute manager.dirty?("test.txt")
    assert_equal "buffered content\n", File.read(file_path)
  end

  def test_apply_emits_buffer_apply_conflict_event
    file_path = File.join(@temp_dir, "conflict.txt")
    File.write(file_path, "version 1\n")

    conflict_events = []
    @event_bus.subscribe(:buffer_apply_conflict) do |payload|
      conflict_events << payload
    end

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.read("conflict.txt")
    manager.write("conflict.txt", "version buffer\n")

    # External modification
    File.write(file_path, "version external\n")

    manager.apply!

    assert_equal 1, conflict_events.size
    assert_equal "conflict.txt", conflict_events.first[:path]
    assert_equal ["conflict.txt"], conflict_events.first[:paths]
  end

  def test_apply_conflict_when_new_file_created_on_disk_externally
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.write("new_file.txt", "buffered new file\n")

    # External actor created the file before apply
    File.write(File.join(@temp_dir, "new_file.txt"), "external unexpected file\n")

    applied = manager.apply!

    assert_empty applied
    assert_equal ["new_file.txt"], manager.last_conflicts
    assert_equal "external unexpected file\n", File.read(File.join(@temp_dir, "new_file.txt"))
  end

  def test_apply_clean_write_no_conflict
    file_path = File.join(@temp_dir, "clean.txt")
    File.write(file_path, "clean baseline\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.read("clean.txt")
    manager.write("clean.txt", "clean modification\n")

    applied = manager.apply!

    assert_equal ["clean.txt"], applied
    assert_empty manager.last_conflicts
    assert_equal "clean modification\n", File.read(file_path)
  end

  def test_apply_partial_success_with_mixed_conflict_and_clean
    f1 = File.join(@temp_dir, "f1.txt")
    f2 = File.join(@temp_dir, "f2.txt")
    File.write(f1, "f1 init\n")
    File.write(f2, "f2 init\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.read("f1.txt")
    manager.read("f2.txt")
    manager.write("f1.txt", "f1 buffer\n")
    manager.write("f2.txt", "f2 buffer\n")

    # Modify f1 on disk, leave f2 unchanged
    File.write(f1, "f1 external\n")

    applied = manager.apply!

    assert_equal ["f2.txt"], applied
    assert_equal ["f1.txt"], manager.last_conflicts
    assert_equal "f1 external\n", File.read(f1)
    assert_equal "f2 buffer\n", File.read(f2)
  end

  def test_reset_clears_last_conflicts
    f1 = File.join(@temp_dir, "f1.txt")
    File.write(f1, "init\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.read("f1.txt")
    manager.write("f1.txt", "buffer\n")
    File.write(f1, "external\n")

    manager.apply!
    assert_equal ["f1.txt"], manager.last_conflicts

    manager.reset!
    assert_empty manager.last_conflicts
  end

  def test_apply_buffer_tool_output_includes_conflict_warning
    f1 = File.join(@temp_dir, "test.txt")
    File.write(f1, "init\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    manager.read("test.txt")
    manager.write("test.txt", "buffer mod\n")
    File.write(f1, "ext mod\n")

    tool = Rubik::Tools::ApplyBufferTool.new(manager)
    result = tool.execute

    assert_includes result, "[CONFLICT] test.txt:"
    assert_includes result, "disk content changed since last read — skipped to prevent data loss."
    assert_includes result, 'Call read_file(path: "test.txt", reload: true)'
  end

  def test_read_file_tool_supports_reload_param
    file_path = File.join(@temp_dir, "test.txt")
    File.write(file_path, "initial content\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    tool = Rubik::Tools::ReadFileTool.new(manager)

    # Schema exposes reload
    assert_equal "boolean", tool.params_schema.dig(:properties, :reload, :type)

    manager.read("test.txt")
    manager.write("test.txt", "dirty buffer content\n")

    # External modification
    File.write(file_path, "fresh external content\n")

    # Standard read_file returns dirty buffer
    buffered = tool.execute("path" => "test.txt")
    assert_includes buffered, "dirty buffer content"
    assert manager.dirty?("test.txt")

    # read_file with reload: true fetches from disk and clears dirty buffer
    reloaded = tool.execute("path" => "test.txt", "reload" => true)
    assert_includes reloaded, "fresh external content"
    refute manager.dirty?("test.txt")
  end

  def test_context_builder_renders_conflicts_in_buffer_xml
    file_path = File.join(@temp_dir, "conflict_file.rb")
    File.write(file_path, "disk 1\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    manager.read("conflict_file.rb")
    manager.write("conflict_file.rb", "buf 1\n")
    File.write(file_path, "disk 2\n")

    manager.apply!
    assert_equal ["conflict_file.rb"], manager.last_conflicts

    xml = Rubik::Prompt::ContextBuilder.build_buffer_xml(manager)
    assert_includes xml, '<conflicts count="1">'
    assert_includes xml, "<conflict>conflict_file.rb</conflict>"
    assert_includes xml, "Conflict: 1 file(s) had external disk modifications"
  end

  def test_context_builder_operational_rules_includes_conflict_guidance
    xml = Rubik::Prompt::ContextBuilder.build_operational_rules_xml
    assert_includes xml, "read_file(path: \"...\", reload: true)"
  end

  def test_read_with_reload_resolves_conflict_by_syncing_with_disk
    file_path = File.join(@temp_dir, "test.txt")
    File.write(file_path, "initial content\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    manager.read("test.txt")
    manager.write("test.txt", "buffered content\n")

    # External modification
    File.write(file_path, "external modified content\n")

    # Before reload, normal read returns dirty buffer
    assert_equal "buffered content\n", manager.read("test.txt")
    assert manager.dirty?("test.txt")

    # Re-reading with reload: true fetches fresh disk content and clears dirty buffer & conflicts
    fresh = manager.read("test.txt", reload: true)
    assert_equal "external modified content\n", fresh
    refute manager.dirty?("test.txt")
    assert_empty manager.last_conflicts
  end

  def test_discard_clears_dirty_buffer_and_conflicts
    file_path = File.join(@temp_dir, "test.txt")
    File.write(file_path, "initial content\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    manager.read("test.txt")
    manager.write("test.txt", "buffered content\n")

    assert manager.dirty?("test.txt")
    manager.discard("test.txt")
    refute manager.dirty?("test.txt")
    assert_equal "initial content\n", manager.read("test.txt")
  end
end
