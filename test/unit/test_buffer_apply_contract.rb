# frozen_string_literal: true

require_relative "../test_helper"

# Issue #146: the apply authority and the partial-apply result contract.
# - buffer.model_can_apply resolves even when the tool is rebuilt without a
#   shell (ScopedRegistry branch workspaces) and gates the MODEL tool only;
#   the operator !apply flow keeps working.
# - A partial apply is never presented as full success: the tool and the
#   REPL name the files that DID reach disk, the failure, and the dirty
#   remainder a retry will write.
class TestBufferApplyContract < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_apply_contract")
    @temp_home = Dir.mktmpdir("rubik_apply_contract_home")
    @event_bus = Rubik::EventBus.new
  end

  def teardown
    remove_temp_dir(@temp_dir)
    remove_temp_dir(@temp_home)
  end

  class FakeShell
    attr_reader :config, :synced

    def initialize(config)
      @config = config
      @synced = []
    end

    def sync_context_and_ast(paths)
      @synced.concat(paths)
    end
  end

  class FakeCtx
    attr_reader :out, :buffer_manager, :synced

    def initialize(buffer_manager)
      @buffer_manager = buffer_manager
      @out = StringIO.new
      @synced = []
    end

    def sync_context_and_ast(paths)
      @synced.concat(paths)
    end
  end

  def dirty_three_files(manager)
    ["a.txt", "b.txt", "c.txt"].each do |f|
      File.write(File.join(@temp_dir, f), "original #{f}\n")
      manager.read(f)
      manager.write(f, "buffered #{f}\n")
    end
  end

  def failing_write_for(basename)
    original = Rubik::Platform.method(:atomic_write)
    lambda do |path, content|
      raise Errno::EACCES, "simulated permission loss" if File.basename(path) == basename

      original.call(path, content)
    end
  end

  def build_repl_apply_handler
    handlers = {}
    fake_shell = Object.new
    fake_shell.define_singleton_method(:register_command) do |name, **_opts, &blk|
      handlers[name] = blk
    end
    Rubik::REPL::Commands::Buffer.register(fake_shell)
    handlers.fetch("apply")
  end

  # ── model authority (buffer.model_can_apply) ─────────────────────────

  def test_model_can_apply_false_blocks_tool_even_without_a_shell
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set("buffer.model_can_apply", false)
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, config: config, event_bus: @event_bus)
    dirty_three_files(manager)

    # The ScopedRegistry rebuilds ApplyBufferTool for branch workspaces with
    # no shell at all — the knob must still be honored there.
    tool = Rubik::Tools::ApplyBufferTool.new(manager)
    res = tool.execute

    assert res.error?, "tool must report refusal as an error"
    assert_includes res, "disabled by configuration (buffer.model_can_apply: false)"
    assert_equal "original a.txt\n", File.read(File.join(@temp_dir, "a.txt")), "model must not write to disk"
    assert manager.dirty?("a.txt"), "buffer stays dirty for the operator"
  end

  def test_operator_apply_flow_works_when_model_can_apply_false
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set("buffer.model_can_apply", false)
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, config: config, event_bus: @event_bus)
    dirty_three_files(manager)

    ctx = FakeCtx.new(manager)
    build_repl_apply_handler.call([], ctx)

    assert_includes ctx.out.string, "Applied changes to 3 file(s): a.txt, b.txt, c.txt"
    assert_equal "buffered a.txt\n", File.read(File.join(@temp_dir, "a.txt"))
    refute manager.dirty?
  end

  # ── partial apply reporting: tool plane ──────────────────────────────

  def test_apply_buffer_tool_reports_partial_apply_with_disk_truth
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    dirty_three_files(manager)
    shell = FakeShell.new(nil)
    tool = Rubik::Tools::ApplyBufferTool.new(manager, shell)

    res = nil
    Rubik::Platform.stub(:atomic_write, failing_write_for("b.txt")) do
      res = tool.execute
    end

    assert res.error?, "partial apply must not be presented as success"
    refute_includes res, "Successfully applied"
    assert_includes res, "Apply stopped before completing; the buffer is not a multi-file transaction:"
    assert_includes res, "Already written to disk (do not re-apply): a.txt"
    assert_includes res, "Failed: b.txt (Errno::EACCES:"
    assert_includes res, "simulated permission loss"
    assert_includes res, "Still dirty — a retry writes only these: c.txt"
    assert_equal ["a.txt"], shell.synced, "files that reached disk must be synced into context/AST"

    # disk truth: a.txt written, b.txt/c.txt untouched and still dirty
    assert_equal "buffered a.txt\n", File.read(File.join(@temp_dir, "a.txt"))
    assert_equal "original b.txt\n", File.read(File.join(@temp_dir, "b.txt"))
    assert manager.dirty?("b.txt")
    assert manager.dirty?("c.txt")
  end

  def test_apply_buffer_tool_retry_writes_only_the_remainder
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    dirty_three_files(manager)
    shell = FakeShell.new(nil)
    tool = Rubik::Tools::ApplyBufferTool.new(manager, shell)

    Rubik::Platform.stub(:atomic_write, failing_write_for("b.txt")) do
      tool.execute
    end

    retry_res = tool.execute
    assert_includes retry_res, "Successfully applied 2 modified file(s) to disk: b.txt, c.txt"
    assert_equal "buffered b.txt\n", File.read(File.join(@temp_dir, "b.txt"))
    assert_equal "buffered c.txt\n", File.read(File.join(@temp_dir, "c.txt"))
    refute manager.dirty?
  end

  def test_sync_failure_does_not_swallow_the_partial_report
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    dirty_three_files(manager)
    shell = FakeShell.new(nil)
    def shell.sync_context_and_ast(_paths)
      raise "index exploded"
    end
    tool = Rubik::Tools::ApplyBufferTool.new(manager, shell)

    res = nil
    Rubik::Platform.stub(:atomic_write, failing_write_for("b.txt")) do
      res = tool.execute
    end

    assert res.error?
    assert_includes res, "Already written to disk (do not re-apply): a.txt"
    assert_includes res, "context/AST sync failed for the already-written files: RuntimeError: index exploded"
    assert_includes res, "Still dirty — a retry writes only these: c.txt"
  end

  # ── partial apply reporting: operator plane ──────────────────────────

  def test_repl_apply_reports_partial_failure_with_disk_truth
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    dirty_three_files(manager)

    ctx = FakeCtx.new(manager)
    Rubik::Platform.stub(:atomic_write, failing_write_for("b.txt")) do
      build_repl_apply_handler.call([], ctx)
    end

    assert_includes ctx.out.string, "Apply stopped before completing; the buffer is not a multi-file transaction:"
    assert_includes ctx.out.string, "Already written to disk (do not re-apply): a.txt"
    assert_includes ctx.out.string, "Failed: b.txt (Errno::EACCES:"
    assert_includes ctx.out.string, "simulated permission loss"
    assert_includes ctx.out.string, "Still dirty — a retry writes only these: c.txt"
    assert_equal ["a.txt"], ctx.synced

    # retry through the operator plane writes only the remainder
    ctx2 = FakeCtx.new(manager)
    build_repl_apply_handler.call([], ctx2)
    assert_includes ctx2.out.string, "Applied changes to 2 file(s): b.txt, c.txt"
    refute manager.dirty?
  end

  def test_repl_apply_reports_conflicts_after_partial_failure
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    # Conflict first, then an applied file, then the failing write — so the
    # failure report carries a conflict AND a partial write in one run.
    ["conflict.txt", "a.txt", "b.txt"].each do |f|
      File.write(File.join(@temp_dir, f), "original #{f}\n")
      manager.read(f)
      manager.write(f, "buffered #{f}\n")
    end
    File.write(File.join(@temp_dir, "conflict.txt"), "externally modified\n")

    ctx = FakeCtx.new(manager)
    Rubik::Platform.stub(:atomic_write, failing_write_for("b.txt")) do
      build_repl_apply_handler.call([], ctx)
    end

    assert_includes ctx.out.string, "Already written to disk (do not re-apply): a.txt"
    assert_includes ctx.out.string, "Failed: b.txt (Errno::EACCES:"
    assert_includes ctx.out.string, "Skipped conflicts (disk changed externally): conflict.txt"
    assert_equal "externally modified\n", File.read(File.join(@temp_dir, "conflict.txt")),
                 "conflict protection must survive the partial failure"
    assert manager.dirty?("conflict.txt"), "the conflicting entry stays dirty for resolution"
  end
end
