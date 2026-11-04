# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/runtime/context"
require "rubik/lsp/client"
require "rubik/lsp/manager"
require "rubik/diagnostics/collector"

class TestLSPZeroRestartInvariants < Minitest::Test
  class FakeClient
    attr_accessor :running, :language, :server_cmd, :closed_files

    def initialize(lang)
      @language = lang
      @running = true
      @server_cmd = "fake-lsp"
      @closed_files = []
    end

    def available?
      true
    end

    def alive?
      @running
    end

    def stop
      @running = false
    end

    def did_close(file_path)
      @closed_files << file_path
      true
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rubik_zero_restart")
    @config = Rubik::Config.new(root_dir: @tmp)
    @context = Rubik::Runtime::Context.new
    @manager = Rubik::LSP::Manager.new(config: @config, root_dir: @tmp, context: @context)
  end

  def teardown
    @manager.stop_all
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_context_unregister_disposable
    inv = @context.register_disposable { "noop" }
    assert_equal 1, @context.disposable_count

    @context.unregister_disposable(inv)
    assert_equal 0, @context.disposable_count
  end

  def test_manager_client_registration_and_unregistration_leaves_zero_disposable_leaks
    initial_count = @context.disposable_count
    client = FakeClient.new("go")

    # Cycle registration and unregistration 50 times
    50.times do
      @manager.send(:register_client_unlocked, "go", client)
      assert @context.has?("lsp:go")

      @manager.send(:unregister_client_unlocked, "go")
      refute @context.has?("lsp:go")
    end

    assert_equal initial_count, @context.disposable_count,
                 "Accumulator disposables must return to baseline after register/unregister cycles"
  end

  def test_manager_did_close_file_delegates_to_client
    client = FakeClient.new("ruby")
    @manager.instance_variable_get(:@clients)["ruby"] = client

    assert @manager.did_close_file("lib/foo.rb")
    assert_equal ["lib/foo.rb"], client.closed_files
  end

  def test_sanitized_spawn_env_unsets_bundler_and_ruby_options
    client = Rubik::LSP::Client.new("ruby", root_dir: @tmp)
    env = client.send(:sanitized_spawn_env)

    ENV.each_key do |k|
      if k.start_with?("BUNDLE_", "BUNDLER_") || %w[RUBYOPT RUBYLIB].include?(k)
        assert_nil env[k], "#{k} must be explicitly mapped to nil to unset in child process"
      end
    end
  end

  def test_normalize_sync_capabilities_infers_open_close_when_omitted_from_hash
    client = Rubik::LSP::Client.new("go", root_dir: @tmp)

    # Hash with change: 1 and no openClose key
    caps1 = client.send(:normalize_sync_capabilities, { "change" => 1 })
    assert_equal true, caps1[:open_close], "open_close must be inferred true for change > 0"
    assert_equal 1, caps1[:change]

    # Hash with change: 0 and no openClose key
    caps0 = client.send(:normalize_sync_capabilities, { "change" => 0 })
    assert_equal false, caps0[:open_close], "open_close must be false when change is 0"

    # Explicit openClose: false overrides
    caps_explicit = client.send(:normalize_sync_capabilities, { "change" => 1, "openClose" => false })
    assert_equal false, caps_explicit[:open_close]
  end

  def test_collector_normalizes_windows_paths_case_insensitively
    collector = Rubik::Diagnostics::Collector.new(root_dir: "C:/Projects/Rubik")
    rel = collector.send(:normalize_rel_path, "c:/projects/rubik/src/main.rs")
    assert_equal "src/main.rs", rel
  end
end
