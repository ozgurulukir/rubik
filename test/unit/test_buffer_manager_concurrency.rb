# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class TestBufferManagerConcurrency < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("rubik_buffer_concurrency_test")
    @manager = Rubik::Buffer::Manager.new(root_dir: @tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_concurrent_writes_and_reads_from_multiple_threads
    thread_count = 8
    iterations_per_thread = 50

    threads = thread_count.times.map do |thread_idx|
      Thread.new do
        iterations_per_thread.times do |iter|
          file_name = "file_#{thread_idx}_#{iter % 5}.txt"
          content = "thread #{thread_idx} data iteration #{iter}\n"

          # Write
          @manager.write(file_name, content)

          # Read back
          read_content = @manager.read(file_name)
          assert read_content.is_a?(String)

          # Query dirty
          assert @manager.dirty?

          # List files
          files = @manager.all_files
          assert files.is_a?(Array)
        end
      end
    end

    threads.each(&:join)

    # Verify no corruption occurred
    assert @manager.dirty?
    assert_operator @manager.dirty_files.size, :>, 0
  end

  def test_concurrent_snapshot_and_restore_operations
    @manager.write("base.txt", "initial")
    snapshot = @manager.snapshot_state

    threads = 4.times.map do |idx|
      Thread.new do
        10.times do |i|
          @manager.write("worker_#{idx}.txt", "payload #{i}")
          snap = @manager.snapshot_state
          assert snap.key?("base.txt")
          @manager.restore_snapshot_state(snapshot) if i.even?
        end
      end
    end

    threads.each(&:join)
  end

  def test_concurrent_apply_and_reset_without_deadlock
    threads = 4.times.map do |idx|
      Thread.new do
        5.times do |i|
          path = "test_apply_#{idx}_#{i}.txt"
          @manager.write(path, "content #{i}")
          @manager.apply!([path])
          @manager.reset! if i == 4
        end
      end
    end

    threads.each(&:join)
  end

  def test_conflict_recovery_with_read_reload_and_discard_does_not_raise_frozen_error
    path = File.join(@manager.root_dir, "foo.rb")
    File.write(path, "v1\n")
    @manager.read("foo.rb")
    @manager.write("foo.rb", "buffered\n")
    File.write(path, "external\n")

    @manager.apply!(["foo.rb"], policy: :skip)
    assert_equal ["foo.rb"], @manager.last_conflicts

    reloaded = @manager.read("foo.rb", reload: true)
    assert_equal "external\n", reloaded
    assert_empty @manager.last_conflicts

    @manager.write("foo.rb", "buffered2\n")
    File.write(path, "external2\n")
    @manager.apply!(["foo.rb"], policy: :skip)
    assert_equal ["foo.rb"], @manager.last_conflicts

    @manager.discard("foo.rb")
    assert_empty @manager.last_conflicts
  end

  def test_all_files_keeps_github_while_pruning_git_metadata
    FileUtils.mkdir_p(File.join(@manager.root_dir, ".git/objects"))
    File.write(File.join(@manager.root_dir, ".git/config"), "gitcfg")
    FileUtils.mkdir_p(File.join(@manager.root_dir, ".github/workflows"))
    File.write(File.join(@manager.root_dir, ".github/workflows/ci.yml"), "name: CI")

    files = @manager.all_files
    assert_includes files, ".github/workflows/ci.yml"
    refute(files.any? { |f| f.start_with?(".git/") })
  end
end
