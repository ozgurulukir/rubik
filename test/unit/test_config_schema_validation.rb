# frozen_string_literal: true

require_relative "../test_helper"

class TestConfigSchemaValidation < Minitest::Test
  def test_boolean_coercion_and_validation
    assert_equal true, Rubik::Config::Schema.coerce("llm.stream", "true")
    assert_equal true, Rubik::Config::Schema.coerce("llm.stream", "yes")
    assert_equal true, Rubik::Config::Schema.coerce("llm.stream", "1")
    assert_equal false, Rubik::Config::Schema.coerce("llm.stream", "false")
    assert_equal false, Rubik::Config::Schema.coerce("llm.stream", "no")
    assert_equal false, Rubik::Config::Schema.coerce("llm.stream", "0")

    assert Rubik::Config::Schema.validate_value!("llm.stream", true, strict: true)
    assert Rubik::Config::Schema.validate_value!("llm.stream", false, strict: true)

    err = assert_raises(ArgumentError) do
      Rubik::Config::Schema.validate_value!("llm.stream", "not_a_boolean", strict: true)
    end
    assert_includes err.message, "must be a boolean"
  end

  def test_integer_coercion_and_boundary_validation
    assert_equal 45, Rubik::Config::Schema.coerce("tools.timeout_seconds", "45")

    assert Rubik::Config::Schema.validate_value!("tools.timeout_seconds", 30, strict: true)

    # Below min (1)
    err = assert_raises(ArgumentError) do
      Rubik::Config::Schema.validate_value!("tools.timeout_seconds", 0, strict: true)
    end
    assert_includes err.message, "must be an integer >= 1"
  end

  def test_float_coercion_and_range_validation
    assert_equal 0.75, Rubik::Config::Schema.coerce("agent.warn_at_ratio", "0.75")

    assert Rubik::Config::Schema.validate_value!("agent.warn_at_ratio", 0.5, strict: true)

    # Exceeds max 1.0
    err = assert_raises(ArgumentError) do
      Rubik::Config::Schema.validate_value!("agent.warn_at_ratio", 1.5, strict: true)
    end
    assert_includes err.message, "must be a float between 0.0 and 1.0"
  end

  def test_enum_coercion_and_validation
    assert_equal "on_finish", Rubik::Config::Schema.coerce("buffer.auto_apply", "ON_FINISH")

    assert Rubik::Config::Schema.validate_value!("buffer.auto_apply", "on_test", strict: true)

    err = assert_raises(ArgumentError) do
      Rubik::Config::Schema.validate_value!("buffer.auto_apply", "sometimes", strict: true)
    end
    assert_includes err.message, "must be one of"
  end

  def test_free_form_string_keys_pass_through
    # sandbox.driver is type :string — the driver registry is dynamically
    # extensible (plugins register drivers), so the value space is open.
    assert_equal "DOCKER", Rubik::Config::Schema.coerce("sandbox.driver", "DOCKER")
    assert Rubik::Config::Schema.validate_value!("sandbox.driver", "custom_plugin_driver", strict: true)

    err = assert_raises(ArgumentError) do
      Rubik::Config::Schema.validate_value!("sandbox.driver", 42, strict: true)
    end
    assert_includes err.message, "must be a string"
  end

  def test_whole_section_write_is_coerced_and_validated
    temp_dir = Dir.mktmpdir
    temp_home = Dir.mktmpdir
    config = Rubik::Config.new(root_dir: temp_dir, home_dir: temp_home)

    # Coercion applies to nested leaves of a spec'd section...
    config.set("tools", { "max_output_chars" => "500" }, persist: false)
    assert_equal 500, config.fetch("tools.max_output_chars")

    # ...the caller's own Hash is not mutated (no aliasing into config state)...
    caller_hash = { "max_output_chars" => "500" }
    config.set("tools", caller_hash, persist: false)
    assert_equal "500", caller_hash["max_output_chars"]

    # ...violations raise strictly, and open sections accept arbitrary keys
    # without "Unknown config key" warnings.
    assert_raises(ArgumentError) { config.set("tools", { "timeout_seconds" => 0 }, persist: false) }
    config.warnings.clear if config.respond_to?(:warnings)
    assert_empty config.warnings
    config.set("providers", { "myprovider" => { "name" => "x" } }, persist: false)
    assert_empty config.warnings
  ensure
    FileUtils.remove_entry(temp_dir)
    FileUtils.remove_entry(temp_home)
  end

  def test_scoped_hash_overrides_are_coerced_and_validated
    temp_dir = Dir.mktmpdir
    temp_home = Dir.mktmpdir
    parent = Rubik::Config.new(root_dir: temp_dir, home_dir: temp_home)

    # Nested leaves coerce like dotted-key writes...
    scoped = parent.extend("tools" => { "max_output_chars" => "500" })
    assert_equal 500, scoped.fetch("tools.max_output_chars")

    # ...and violations raise instead of being silently stored.
    err = assert_raises(ArgumentError) do
      parent.extend("tools" => { "timeout_seconds" => 0 })
    end
    assert_includes err.message, "tools.timeout_seconds"
  ensure
    FileUtils.remove_entry(temp_dir)
    FileUtils.remove_entry(temp_home)
  end
end
