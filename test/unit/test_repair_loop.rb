# frozen_string_literal: true

require_relative "../test_helper"

class TestRepairLoop < Minitest::Test
  class MockRepairProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      super()
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      text = @responses.shift || "def valid; end"
      Rubik::LLM::Response.new(text: text)
    end
  end

  class MockAdapter < Rubik::Adapter::BaseAdapter
    def initialize(results)
      super("mock", "ruby")
      @results = results.dup
    end

    def check_syntax(_file_path)
      @results.shift || { ok: true, output: "", duration: 0.0 }
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir
    @snap_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @snapshot_store = Rubik::Buffer::SnapshotStore.new(storage_dir: @snap_dir)
    @adapter_registry = Rubik::Adapter::Registry.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@snap_dir)
  end

  def test_successful_first_repair_attempt
    provider = MockRepairProvider.new(["```ruby\ndef hello\n  'fixed'\nend\n```"])
    adapter = MockAdapter.new([{ ok: true }])
    @adapter_registry.register("ruby", adapter)

    loop_engine = Rubik::Repair::Loop.new(
      provider: provider,
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      adapter_registry: @adapter_registry
    )

    diags = [Rubik::Diagnostics::Entry.new(message: "syntax error", category: :syntax)]
    res = loop_engine.repair(diags, "app.rb", :ruby)

    assert res[:ok]
    assert_equal 1, res[:attempts]
    assert_equal "def hello\n  'fixed'\nend", @buffer_manager.read("app.rb")
  end

  def test_repair_fails_when_max_attempts_exceeded
    provider = MockRepairProvider.new(["def broken_v1; end", "def broken_v2; end"])
    adapter = MockAdapter.new([{ ok: false, output: "err 1" }, { ok: false, output: "err 2" }])
    @adapter_registry.register("ruby", adapter)

    loop_engine = Rubik::Repair::Loop.new(
      provider: provider,
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      adapter_registry: @adapter_registry,
      max_attempts: 2
    )

    diags = [Rubik::Diagnostics::Entry.new(message: "syntax error", category: :syntax)]
    res = loop_engine.repair(diags, "app.rb", :ruby)

    refute res[:ok]
    assert_equal 2, res[:attempts]
  end

  # ── Plan 86 D-2 pin tests: iç yardımcıların mevcut davranışı ──────────

  def test_extract_code_strips_language_tag_from_first_fenced_segment
    engine = build_engine

    assert_equal "def x; end", engine.send(:extract_code, "```ruby\ndef x; end\n```")
    assert_equal "def y; end", engine.send(:extract_code, "```\ndef y; end\n```")
    assert_equal "x", engine.send(:extract_code, "prose```ruby\nx\n```trailer```other```")
    assert_equal "plain text", engine.send(:extract_code, "  plain text  ")
  end

  def test_check_buffer_syntax_short_circuits_without_adapter
    engine = build_engine

    result = engine.send(:check_buffer_syntax, "missing.cb", :cobol) # kayıtlı adapter'ı olmayan dil

    assert_equal({ ok: true }, result)
  end

  def test_check_buffer_syntax_writes_buffer_content_to_tempfile_for_adapter
    File.write(File.join(@temp_dir, "app.rb"), "def current; end")
    capturing = PathCaptureAdapter.new
    @adapter_registry.register("ruby", capturing)
    engine = build_engine

    engine.send(:check_buffer_syntax, "app.rb", :ruby)

    assert_equal 1, capturing.seen_paths.size
    assert_match(/rubik_repair_.*\.rb\z/, File.basename(capturing.seen_paths.first))
    assert_equal "def current; end", capturing.seen_contents.first
  end

  def test_build_repair_prompt_scopes_attempt_and_includes_context
    File.write(File.join(@temp_dir, "app.rb"), "def current; end")
    diag = Object.new
    def diag.format_prompt_snippet(*_args)
      "DIAG-1"
    end
    engine = build_engine(max_attempts: 3)

    prompt = engine.send(:build_repair_prompt, [diag], "app.rb", 2)

    assert_includes prompt, "Attempt 2 of 3"
    assert_includes prompt, "app.rb"
    assert_includes prompt, "def current; end"
    assert_includes prompt, "DIAG-1"
    assert_includes prompt, "```"
  end

  private

  def build_engine(max_attempts: nil)
    Rubik::Repair::Loop.new(
      provider: MockRepairProvider.new([]),
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      adapter_registry: @adapter_registry,
      max_attempts: max_attempts
    )
  end

  class PathCaptureAdapter < Rubik::Adapter::BaseAdapter
    attr_reader :seen_paths, :seen_contents

    def initialize
      super("pathcap", "ruby")
      @seen_paths = []
      @seen_contents = []
    end

    def check_syntax(file_path)
      @seen_paths << file_path
      @seen_contents << File.read(file_path)
      { ok: true, output: "", duration: 0.0 }
    end
  end
end
