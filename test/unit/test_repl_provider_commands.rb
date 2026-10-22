# frozen_string_literal: true

require_relative "../test_helper"

class TestReplProviderCommands < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_provider_project")
    @temp_home = Dir.mktmpdir("rubik_provider_home")
    @out = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out)
  end

  def teardown
    begin
      FileUtils.remove_entry(@temp_root)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@temp_home)
    rescue
      nil
    end
  end

  def test_provider_list_and_status
    @out.reopen
    @shell.execute_input("!provider list")
    assert_includes @out.string, "=== Configured LLM Providers & Models ==="

    @out.reopen
    @shell.execute_input("!provider status")
    assert_includes @out.string, "=== Configured LLM Providers & Models ==="
  end

  def test_provider_add_validation
    # Missing args
    @out.reopen
    @shell.execute_input("!provider add")
    assert_includes @out.string, "Usage: !provider add"

    # Missing endpoint
    @out.reopen
    @shell.execute_input("!provider add testprov")
    assert_includes @out.string, "Usage: !provider add"

    # Invalid endpoint schema with explicit type and invalid url
    @out.reopen
    @shell.execute_input("!provider add testprov customtype ftp://example.com")
    assert_includes @out.string, "Error: Endpoint must be a valid HTTP/HTTPS URL"
  end

  def test_provider_add_success
    @out.reopen
    @shell.execute_input("!provider add myprov openai https://api.openai.com/v1 --key=secret123 --model=gpt-4o --context=65536")
    assert_includes @out.string, "Successfully added provider 'myprov'"

    prov_spec = @shell.config.provider_spec("myprov")
    refute_nil prov_spec
    assert_equal "openai", prov_spec["type"]
    assert_equal "https://api.openai.com/v1/chat/completions", prov_spec["endpoint"]
    assert_equal "secret123", prov_spec["api_key"]
    assert_equal [{ "name" => "gpt-4o", "context_limit" => 65_536 }], prov_spec["models"]
  end

  def test_provider_add_and_remove_model
    # First add a provider
    @shell.execute_input("!provider add myprov https://api.example.com")

    # Missing args for add-model
    @out.reopen
    @shell.execute_input("!provider add-model myprov")
    assert_includes @out.string, "Usage: !provider add-model"

    # Add model successfully
    @out.reopen
    @shell.execute_input("!provider add-model myprov custom-model --context=16384")
    assert_includes @out.string, "Added model 'custom-model' (16384 tokens) to provider 'myprov'"

    # Remove model missing args
    @out.reopen
    @shell.execute_input("!provider remove-model myprov")
    assert_includes @out.string, "Usage: !provider remove-model"

    # Remove model success
    @out.reopen
    @shell.execute_input("!provider remove-model myprov custom-model")
    assert_includes @out.string, "Removed model 'custom-model' from provider 'myprov'"
  end

  def test_provider_set_field
    @shell.execute_input("!provider add myprov https://api.example.com")

    # Missing args
    @out.reopen
    @shell.execute_input("!provider set myprov key")
    assert_includes @out.string, "Usage: !provider set"

    # Set key
    @out.reopen
    @shell.execute_input("!provider set myprov key new_key_val")
    assert_includes @out.string, "Updated provider 'myprov' field 'key' to 'new_key_val'"
    assert_equal "new_key_val", @shell.config.provider_spec("myprov")["api_key"]

    # Set endpoint (valid and invalid)
    @out.reopen
    @shell.execute_input("!provider set myprov endpoint invalid_url")
    assert_includes @out.string, "Error: Endpoint must be a valid HTTP/HTTPS URL"

    @out.reopen
    @shell.execute_input("!provider set myprov endpoint https://new.example.com")
    assert_includes @out.string, "Updated provider 'myprov' field 'endpoint'"
    assert_equal "https://new.example.com", @shell.config.provider_spec("myprov")["endpoint"]

    # Set boolean scalar
    @out.reopen
    @shell.execute_input("!provider set myprov stream false")
    assert_includes @out.string, "Updated provider 'myprov' field 'stream' to 'false'"
    assert_equal false, @shell.config.provider_spec("myprov")["stream"]
  end

  def test_provider_remove
    @shell.execute_input("!provider add myprov https://api.example.com")

    @out.reopen
    @shell.execute_input("!provider remove myprov")
    assert_includes @out.string, "Removed provider 'myprov'"
    assert_nil @shell.config.provider_spec("myprov")

    # Removing non-existent
    @out.reopen
    @shell.execute_input("!provider remove myprov")
    assert_includes @out.string, "Provider 'myprov' not found."
  end

  def test_provider_set_context
    @shell.execute_input("!provider add myprov https://api.example.com")

    # Missing or invalid args
    @out.reopen
    @shell.execute_input("!provider set-context myprov default 0")
    assert_includes @out.string, "Usage: !provider set-context"

    # Success
    @out.reopen
    @shell.execute_input("!provider set-context myprov default 12345")
    assert_includes @out.string, "Updated context limit for model 'default' on provider 'myprov' to 12345 tokens"
  end

  def test_provider_usage_fallback
    @out.reopen
    @shell.execute_input("!provider invalid_subcommand")
    assert_includes @out.string, "Usage: !provider"
  end
end
