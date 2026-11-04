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
end
