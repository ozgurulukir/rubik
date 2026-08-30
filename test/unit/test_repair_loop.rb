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
end
