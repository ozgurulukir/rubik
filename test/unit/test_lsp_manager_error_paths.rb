# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

# G13 remainder: LSP::Manager crash-record arms. A dead or failing client
# must be stopped (with a raising stop swallowed), dropped from the registry
# and its crash recorded — never allowed to raise into the caller. All tests
# run against in-memory client doubles; no language server is spawned.
class TestLspManagerErrorPaths < Minitest::Test
  # A client double that reports running-but-dead and whose stop explodes —
  # the shape that drives every stop-rescue arm in the manager.
  class DeadClient
    attr_accessor :available, :start_ok, :server_cmd, :running

    def initialize
      @available = true
      @start_ok = false
      @server_cmd = "fake-lsp"
      @running = true
    end

    def alive? = false
    def language = "ruby"
    def stop = raise IOError, "stop boom"
    def available? = @available
    def start = @start_ok
  end

  class UnavailableClient < DeadClient
    def initialize
      super
      @available = false
    end
  end

  class LiveClient
    def running = true
    def alive? = true
    def language = "ruby"
  end

  def setup
    @tmp = Dir.mktmpdir("rubik_lsp_mgr_err")
    # Plain hash with explicit keys: bare Hash#fetch (no default arg) must not
    # raise, and lsp.enabled must be true so the manager's gates are open.
    @mgr = Rubik::LSP::Manager.new(
      config: { "lsp.enabled" => true, "lsp.auto_start" => true, "lsp.servers.ruby" => nil },
      root_dir: @tmp
    )
  end

  def teardown
    @mgr.instance_variable_get(:@clients).clear
    remove_temp_dir(@tmp) if File.directory?(@tmp)
  end

  def inject(client)
    @mgr.instance_variable_get(:@clients)["ruby"] = client
    client
  end

  def test_ensure_healthy_drops_dead_client_whose_stop_raises
    # Pass a real Client instance (doubled via singleton methods) so
    # ensure_healthy!'s is_a?(Client) shortcut routes to its OWN dead-client
    # arm instead of delegating to client_for. Client.new is stubbed so the
    # post-crash start_client retry stays hermetic (no real server spawn).
    inst = Rubik::LSP::Client.new("ruby", root_dir: @tmp, server_cmd: "ruby --version")
    def inst.running = true
    def inst.alive? = false
    def inst.stop = raise IOError, "stop boom"

    Rubik::LSP::Client.stub(:new, ->(*, **) { UnavailableClient.new }) do
      capture_io { @mgr.ensure_healthy!(inst) }
    end

    stats = @mgr.instance_variable_get(:@crash_stats)["ruby"]
    assert_equal 1, stats[:count], "ensure_healthy! must record its own crash for the instance path"
  end

  def test_client_for_recreates_dead_client_whose_stop_raises
    inject(DeadClient.new)

    fresh = nil
    Rubik::LSP::Client.stub(:new, ->(*, **) { UnavailableClient.new }) do
      capture_io do
        @mgr.client_for("ruby") # first call drops the dead client, returns nil
        fresh = @mgr.client_for("ruby") # second call takes the recreate branch
      end
    end

    assert_instance_of UnavailableClient, fresh
  end

  def test_client_for_records_crash_when_start_fails
    failing = DeadClient.new # start_ok defaults false, stop raises

    stored = nil
    Rubik::LSP::Client.stub(:new, ->(*, **) { failing }) do
      capture_io { stored = @mgr.client_for("ruby") }
    end

    assert_same failing, stored
    stats = @mgr.instance_variable_get(:@crash_stats)["ruby"]
    assert_equal 1, stats[:count]
  end

  def test_start_client_failure_reports_diagnostic_not_raise
    failing = DeadClient.new
    failing.running = false # start_client short-circuits "already running" otherwise
    res = nil

    Rubik::LSP::Client.stub(:new, ->(*, **) { failing }) do
      capture_io { res = @mgr.start_client("ruby") }
    end

    assert_equal false, res[:ok]
    stats = @mgr.instance_variable_get(:@crash_stats)["ruby"]
    assert_equal 1, stats[:count]
  end

  def test_sync_buffer_dirty_arity_fallback_does_not_raise
    @mgr.instance_variable_get(:@clients)["ruby"] = LiveClient.new
    buffer = Object.new
    buffer.define_singleton_method(:dirty?) do |*args|
      args.empty? ? false : raise(ArgumentError, "arity trap")
    end

    capture_io { @mgr.sync_buffer_file_if_needed(File.join(@tmp, "x.rb"), buffer) }

    assert_empty @mgr.instance_variable_get(:@crash_stats)
  end
end
