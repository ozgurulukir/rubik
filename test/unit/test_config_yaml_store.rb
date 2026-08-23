# frozen_string_literal: true

require_relative "../test_helper"

class TestConfigYamlStore < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_project_yaml_store")
    @temp_home = Dir.mktmpdir("rubik_home_yaml_store")
  end

  def teardown
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_store_for_caches_instances_by_path
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    store1 = config.store_for(:global)
    store2 = config.store_for(:global)
    assert_same store1, store2

    proj_store1 = config.store_for(:project)
    proj_store2 = config.store_for(:project)
    assert_same proj_store1, proj_store2

    refute_same store1, proj_store1
  end

  def test_transaction_read_and_write
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    
    config.transaction(:project) do |store|
      store["custom_section"] = { "enabled" => true, "count" => 42 }
    end

    res = config.transaction(:project, read_only: true) do |store|
      store["custom_section"]
    end

    assert_equal({ "enabled" => true, "count" => 42 }, res)
  end

  def test_transaction_abort_rollbacks_changes
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    
    config.transaction(:global) do |store|
      store["initial_key"] = "original_value"
    end

    config.transaction(:global) do |store|
      store["initial_key"] = "modified_value"
      store["temp_key"] = "should_not_exist"
      store.abort
    end

    config.transaction(:global, read_only: true) do |store|
      assert_equal "original_value", store["initial_key"]
      assert_nil store["temp_key"]
    end
  end

  def test_save_atomic_merge_and_persistence
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    
    # Pre-populate store with custom root
    config.transaction(:global) do |store|
      store["custom_root"] = "persisted_value"
    end

    config.set("model.name", "llama3.3", persist: :global)

    config.transaction(:global, read_only: true) do |store|
      assert_equal "llama3.3", store["model"]["name"]
      assert_equal "persisted_value", store["custom_root"]
    end
  end

  def test_save_handles_schema_validation_error_with_abort
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    
    # Save a valid state first
    config.set("model.provider", "ollama", persist: :global)

    # Force an invalid non-hash data structure
    config.instance_variable_set(:@data, "invalid_non_hash")
    res = config.save!(:global)

    assert_equal false, res[:ok]
    assert_includes res[:error], "Configuration must be a Hash"

    # Reload and verify previous state was preserved
    reloaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal "ollama", reloaded.fetch("model.provider")
  end

  def test_concurrent_transactions_thread_safety
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    threads = []
    iterations = 20

    iterations.times do
      threads << Thread.new do
        config.transaction(:global) do |store|
          current = store["thread_counter"] || 0
          store["thread_counter"] = current + 1
        end
      end
    end

    threads.each(&:join)

    final_count = config.transaction(:global, read_only: true) do |store|
      store["thread_counter"]
    end

    assert_equal iterations, final_count
  end

  def test_root_deletion_via_transaction
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    
    # Store initial roots
    config.transaction(:global) do |store|
      store["obsolete_root"] = { "temp" => true }
      store["keep_root"] = "value"
    end

    config.transaction(:global) do |store|
      store.delete("obsolete_root")
    end

    config.transaction(:global, read_only: true) do |store|
      assert_nil store["obsolete_root"]
      assert_includes store.roots, "keep_root"
      refute_includes store.roots, "obsolete_root"
    end
  end

  def test_backwards_compatibility_with_plain_yaml_files
    # Simulate a config.yml created by standard YAML.dump
    global_dir = File.join(@temp_home, ".rubik")
    FileUtils.mkdir_p(global_dir)
    raw_yaml = <<~YAML
      model:
        provider: custom_ollama
        name: llama3-custom
        host: http://localhost:11434
      tools:
        timeout_seconds: 45
    YAML
    File.write(File.join(global_dir, "config.yml"), raw_yaml)

    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal "custom_ollama", config.fetch("model.provider")
    assert_equal "llama3-custom", config.fetch("model.name")
    assert_equal 45, config.fetch("tools.timeout_seconds")
  end

  def test_deep_stringify_keys_with_symbols_and_nested_structures
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    input = {
      :model => { :provider => :custom, :name => "model-x" },
      :list => [{ :nested_key => :nested_val }, 123, "text"]
    }
    stringified = config.send(:deep_stringify_keys, input)

    expected = {
      "model" => { "provider" => :custom, "name" => "model-x" },
      "list" => [{ "nested_key" => :nested_val }, 123, "text"]
    }
    assert_equal expected, stringified
  end

  def test_read_only_transaction_prevents_modifications
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    
    assert_raises(PStore::Error) do
      config.transaction(:project, read_only: true) do |store|
        store["illegal_write"] = "fail"
      end
    end
  end
end

