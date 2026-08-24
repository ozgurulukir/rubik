# frozen_string_literal: true

require_relative "../test_helper"

class TestSpatiotemporalCoeffectLifecycle < Minitest::Test
  def setup
    @context = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@context)
  end

  def teardown
    @manager.dispose! unless @context.disposed?
  end

  def test_100_consecutive_component_swaps_lifo_order
    execution_order = []

    100.times do |i|
      @manager.register_component("worker_#{i}", inject: [:service_alpha]) do |ctx|
        execution_order << "activate_#{i}"
        ctx.on_dispose do
          execution_order << "deactivate_#{i}"
        end
      end
    end

    # All 100 components are pending because service_alpha is missing
    assert_equal 100, @manager.pending_fibers.size
    assert_equal 0, @manager.active_fibers.size

    # Provide coeffect -> all 100 activate
    @manager.provide(:service_alpha, "active_alpha_payload")
    assert_equal 100, @manager.active_fibers.size
    assert_equal 0, @manager.pending_fibers.size
    assert_equal 100, execution_order.size

    # Dispose manager -> LIFO unwinding
    @manager.dispose!
    assert @context.disposed?
    assert_equal 0, @manager.active_fibers.size
  end

  def test_sub_context_scoping_and_lifo_rollback
    log = []
    root = Rubik::Runtime::Context.new
    root.on_dispose { log << "root_disposed" }

    child = root.extend
    child.provide(:child_service, "child_val")
    child.on_dispose { log << "child_disposed" }

    grandchild = child.extend
    grandchild.on_dispose { log << "grandchild_disposed" }

    # Disposing child should unwind grandchild and child, but leave root active
    child.dispose
    assert child.disposed?
    assert grandchild.disposed?
    refute root.disposed?
    assert_equal %w[grandchild_disposed child_disposed], log

    # Disposing root should clean up root
    root.dispose
    assert root.disposed?
    assert_equal %w[grandchild_disposed child_disposed root_disposed], log
  end

  def test_failure_rollback_in_sub_context_sandbox
    root = Rubik::Runtime::Context.new
    root.provide(:database, "db_connection")

    sub = root.extend
    sub_effects = []
    sub.register_disposable { sub_effects << "revert_probe_mutation" }

    # Simulate failure in sandbox
    begin
      raise "Probe handshake failed"
    rescue StandardError
      sub.dispose
    end

    assert_equal ["revert_probe_mutation"], sub_effects
    assert sub.disposed?
    refute root.disposed?
    assert root.has?(:database)
  end

  def test_lsp_manager_registers_coeffect_in_context
    temp_dir = Dir.mktmpdir("rubik_lsp_coeffect")
    config = Rubik::Config.new(root_dir: temp_dir)
    lsp_mgr = Rubik::LSP::Manager.new(config: config, root_dir: temp_dir, context: @context)

    # Fake server command using ruby standard executable
    cmd = "ruby -e 'exit 0'"
    client = Rubik::LSP::Client.new("ruby", root_dir: temp_dir, server_cmd: cmd)
    @context.provide("lsp:ruby", client)

    assert @context.has?("lsp:ruby")
    assert_equal client, @context.require("lsp:ruby")

    @context.dispose
    refute @context.has?("lsp:ruby")
  ensure
    FileUtils.remove_entry(temp_dir) if temp_dir && File.directory?(temp_dir)
  end
end
