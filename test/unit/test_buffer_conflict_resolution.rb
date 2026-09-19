# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require_relative "../../lib/rubik/buffer/manager"
require_relative "../../lib/rubik/tools/builtins/lifecycle"
require_relative "../../lib/rubik/tools/builtins/files"
require_relative "../../lib/rubik/orchestrator/step_executor"

class TestBufferConflictResolution < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("rubik_conflict_test_")
    @manager = Rubik::Buffer::Manager.new(root_dir: @tmp_dir)
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.directory?(@tmp_dir)
  end

  def test_apply_clears_buffer_and_allows_formatter_sync
    rel_path = "src/app.cr"
    full_path = File.join(@tmp_dir, rel_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "def run\n  puts 1\nend\n")

    # Step 1: Read and modify via buffer
    content = @manager.read(rel_path)
    assert_includes content, "puts 1"

    @manager.write(rel_path, "def run\n  puts 2\nend\n")
    applied = @manager.apply!
    assert_equal [rel_path], applied
    assert_empty @manager.last_conflicts

    # Verify @buffer is evicted on successful apply
    refute @manager.instance_variable_get(:@buffer).key?(rel_path)

    # Step 2: External tool (e.g. crystal tool format / prettier) formats disk file
    File.write(full_path, "def run\n    puts 2\nend\n")

    # Step 3: Next read pulls formatted disk file and updates baseline hash
    new_content = @manager.read(rel_path)
    assert_includes new_content, "    puts 2"
    expected_hash = Digest::SHA256.hexdigest("def run\n    puts 2\nend\n")
    assert_equal expected_hash, @manager.instance_variable_get(:@original_hashes)[rel_path]

    # Step 4: Next modification applies cleanly without false conflict
    @manager.write(rel_path, "def run\n    puts 3\nend\n")
    applied2 = @manager.apply!
    assert_equal [rel_path], applied2
    assert_empty @manager.last_conflicts
    assert_equal "def run\n    puts 3\nend\n", File.read(full_path)
  end

  def test_write_file_new_file_does_not_falsely_conflict
    # A brand-new file has no tracked baseline, so WriteFileTool must apply it
    # without reporting a false external-modification conflict.
    rel_path = "lib/new_module.rb"
    full_path = File.join(@tmp_dir, rel_path)

    tool = Rubik::Tools::WriteFileTool.new(@manager)
    res = tool.execute("path" => rel_path, "content" => "module New\nend\n")
    assert_includes res, "Successfully wrote to in-memory buffer"

    applied = @manager.apply!
    assert_equal [rel_path], applied
    assert_empty @manager.last_conflicts
    assert_equal "module New\nend\n", File.read(full_path)
  end

  def test_write_file_does_not_silently_overwrite_externally_modified_file
    # WriteFileTool must NOT reset the tracked baseline of an already-loaded
    # file. When the disk was externally modified to something differing from
    # the recorded baseline, apply! must report a conflict rather than
    # silently clobbering the external change.
    rel_path = "lib/module.rb"
    full_path = File.join(@tmp_dir, rel_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "module Old\nend\n")

    # Read to establish the original baseline
    @manager.read(rel_path)

    # External modification (e.g. a formatter) changes the disk away from baseline
    File.write(full_path, "module Formatted\nend\n")

    # WriteFileTool writes new content (baseline is intentionally NOT reset)
    tool = Rubik::Tools::WriteFileTool.new(@manager)
    res = tool.execute("path" => rel_path, "content" => "module New\nend\n")
    assert_includes res, "Successfully wrote to in-memory buffer"

    # apply! surfaces the genuine external-modification conflict
    applied = @manager.apply!
    assert_empty applied
    refute_empty @manager.last_conflicts
  end

  def test_apply_buffer_tool_returns_error_and_actionable_guidance_on_conflict
    rel_path = "src/icon.cr"
    full_path = File.join(@tmp_dir, rel_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "A = 1\n")

    @manager.read(rel_path)
    # External modification
    File.write(full_path, "A = 2\n")

    # Surgical replacement or write without reset_baseline
    @manager.write(rel_path, "A = 3\n", reset_baseline: false)

    tool = Rubik::Tools::ApplyBufferTool.new(@manager)
    res = tool.execute({})

    # Must be ToolOutput.error containing [CONFLICT] and actionable advice
    assert_respond_to res, :error?
    assert res.error?
    assert_includes res.to_s, "[CONFLICT]"
    assert_includes res.to_s, "apply_buffer(force: true)"
    assert_includes res.to_s, "read_file(path: \"#{rel_path}\", reload: true)"
  end

  def test_apply_buffer_tool_force_overwrites_conflict
    rel_path = "src/icon.cr"
    full_path = File.join(@tmp_dir, rel_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "A = 1\n")

    @manager.read(rel_path)
    File.write(full_path, "A = 2\n") # external modification

    @manager.write(rel_path, "A = 3\n", reset_baseline: false)

    tool = Rubik::Tools::ApplyBufferTool.new(@manager)
    res = tool.execute("force" => true)

    refute res.respond_to?(:error?)
    assert_includes res.to_s, "Successfully applied 1 modified file(s)"
    assert_equal "A = 3\n", File.read(full_path)

    # Also test string "true" and "overwrite" alias
    File.write(full_path, "A = 4\n")
    @manager.write(rel_path, "A = 5\n", reset_baseline: false)
    res2 = tool.execute("overwrite" => "true")
    refute res2.respond_to?(:error?)
    assert_equal "A = 5\n", File.read(full_path)
  end

  def test_replace_file_content_tolerates_old_and_new_content_aliases
    rel_path = "src/sample.rb"
    full_path = File.join(@tmp_dir, rel_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "def greet\n  puts 'hello'\nend\n")

    tool = Rubik::Tools::ReplaceFileContentTool.new(@manager)

    # Calling with old_content and new_content instead of target_content/replacement_content
    res = tool.execute(
      "path" => rel_path,
      "old_content" => "puts 'hello'",
      "new_content" => "puts 'world'"
    )
    assert_includes res, "Successfully replaced content"

    @manager.apply!
    assert_equal "def greet\n  puts 'world'\nend\n", File.read(full_path)
  end

  def test_step_executor_classifies_conflict_as_error
    assert_includes Rubik::Orchestrator::StepExecutor::ERROR_PREFIXES, "[CONFLICT]"
  end
end
