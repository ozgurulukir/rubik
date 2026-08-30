# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Plan 63 Faz B: Shell#initialize delegates subsystem construction to
# Rubik::REPL::Composition and assigns the built parts. The shell stays the
# coordinator, while every part remains injectable through the parts: kwarg.
class TestREPLComposition < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_build_returns_fully_populated_parts
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir)

    assert_instance_of Rubik::REPL::Composition::Parts, parts
    [:config, :event_bus, :buffer_manager, :snapshot_store, :cache_store, :ast_graph, :context_index, :recorder, :adapter_registry, :llm_registry, :router,
     :runtime_manager, :overlay_storage, :lsp_manager, :guard, :sandbox_runner, :extra_roots, :allowed_ext_dirs].each do |member|
      assert parts[member], "expected #{member} to be constructed"
    end
    assert_equal false, parts.allow_ext_writes
  end

  def test_build_keeps_caller_supplied_objects
    config = Rubik::Config.new(root_dir: @temp_dir)
    bus = Rubik::EventBus.new
    buffer = Rubik::Buffer::Manager.new(root_dir: @temp_dir)

    parts = Rubik::REPL::Composition.build(config: config, root_dir: @temp_dir, event_bus: bus, buffer_manager: buffer)

    assert_same config, parts.config
    assert_same bus, parts.event_bus
    assert_same buffer, parts.buffer_manager
  end

  def test_shell_assigns_built_parts
    config = Rubik::Config.new(root_dir: @temp_dir)
    shell = Rubik::REPL::Shell.new(config: config, output: StringIO.new)

    assert_same config, shell.config
    refute_nil shell.buffer_manager
    refute_nil shell.ast_graph
    refute_nil shell.runtime_manager
    refute_nil shell.tool_registry
  end

  def test_shell_accepts_injected_parts
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir)
    fake_guard = Object.new
    parts[:guard] = fake_guard

    shell = Rubik::REPL::Shell.new(output: StringIO.new, parts: parts)

    assert_same fake_guard, shell.guard
    assert_same parts.buffer_manager, shell.buffer_manager
    assert_same parts.runtime_manager, shell.runtime_manager
    assert_same parts.config, shell.config
  end

  # Plan 63 Faz B: composition.rb is the escape valve that keeps shell.rb
  # under its decoupling cap — it must not grow into a second kitchen sink.
  def test_composition_stays_a_small_construction_module
    lines = File.readlines(File.expand_path("../../lib/rubik/repl/composition.rb", __dir__)).size
    assert_operator lines, :<, 120, "composition.rb must stay a pure construction layer under 120 lines, got #{lines}"
  end
end
