# frozen_string_literal: true

require_relative "../test_helper"

# MCP stdio transports must not leak the host's bundler/Ruby runtime
# environment into server subprocesses: a foreign BUNDLE_GEMFILE or RUBYOPT
# in the child changes what the server loads. The scrub list is single-homed
# in Platform.sanitized_spawn_env (the same one the LSP client applies), and
# explicitly configured env: entries merge on top and win.
#
# Credential policy (issue #429): the host environment is inherited by
# default — including credential-shaped variables, since many real MCP
# servers legitimately need operator credentials. A per-server
# `inherit_env: false` opts out by additionally unsetting variables matching
# /_(API_KEY|TOKEN|SECRET|PASSWORD)\z/i; explicit env: entries always win.
class TestMcpStdioSpawnEnv < Minitest::Test
  def test_spawn_env_unsets_bundler_and_ruby_runtime_variables
    with_env("BUNDLE_GEMFILE" => "/elsewhere/Gemfile", "RUBYOPT" => "-wfoo") do
      env = transport(env: {}).send(:spawn_env)

      assert_nil env["BUNDLE_GEMFILE"], "must be mapped to nil to unset in the child process"
      assert_nil env["RUBYOPT"], "must be mapped to nil to unset in the child process"
    end
  end

  def test_spawn_env_passes_through_unrelated_variables_untouched
    with_env("HOME" => "/tmp/somewhere") do
      env = transport(env: {}).send(:spawn_env)
      refute env.key?("HOME"), "unrelated variables must not appear in the spawn override hash"
    end
  end

  def test_configured_env_entries_override_the_scrub_list
    env = transport(env: { "RUBYOPT" => "-wcustom" }).send(:spawn_env)

    assert_equal "-wcustom", env["RUBYOPT"]
  end

  # Credential policy (issue #429): by default the host environment is
  # inherited, credential-shaped variables included — many real MCP servers
  # need operator credentials (GITHUB_TOKEN etc.).

  def test_default_inherits_credential_shaped_variables
    with_env("TEST_API_KEY" => "test-key-1", "TEST_TOKEN" => "test-token-1") do
      env = transport(env: {}).send(:spawn_env)

      refute env.key?("TEST_API_KEY"), "default must leave credential vars to inherit implicitly"
      refute env.key?("TEST_TOKEN"), "default must leave credential vars to inherit implicitly"
    end
  end

  def test_inherit_env_false_unsets_credential_shaped_variables
    with_env("TEST_API_KEY" => "test-key-1", "TEST_TOKEN" => "test-token-1",
             "TEST_SECRET" => "test-secret-1", "TEST_PASSWORD" => "test-password-1") do
      env = transport(env: {}, inherit_env: false).send(:spawn_env)

      assert_nil env["TEST_API_KEY"], "opt-out must map credential vars to nil to unset them"
      assert_nil env["TEST_TOKEN"]
      assert_nil env["TEST_SECRET"]
      assert_nil env["TEST_PASSWORD"]
    end
  end

  def test_inherit_env_false_is_case_insensitive_on_the_suffix
    with_env("test_github_token" => "test-token-1", "TEST_API_KEY" => "test-key-1") do
      env = transport(env: {}, inherit_env: false).send(:spawn_env)

      assert_nil env["test_github_token"]
      assert_nil env["TEST_API_KEY"]
      # Non-credential vars still inherit implicitly.
      refute env.key?("HOME")
    end
  end

  def test_inherit_env_false_keeps_non_credential_variables_inheriting
    with_env("TEST_TOKENIZER_MODE" => "fast", "API_KEYS_DIR" => "/tmp/keys") do
      env = transport(env: {}, inherit_env: false).send(:spawn_env)

      refute env.key?("TEST_TOKENIZER_MODE"), "only the exact _SUFFIX shape is credential-shaped"
      refute env.key?("API_KEYS_DIR"), "the pattern anchors at the end of the name"
    end
  end

  def test_explicit_env_wins_over_the_credential_strip_in_opt_out_mode
    with_env("TEST_API_KEY" => "test-key-1") do
      env = transport(env: { "TEST_API_KEY" => "test-key-explicit" }, inherit_env: false).send(:spawn_env)

      assert_equal "test-key-explicit", env["TEST_API_KEY"]
    end
  end

  def test_explicit_env_wins_over_the_scrub_list_and_inheritance_in_default_mode
    with_env("TEST_API_KEY" => "test-key-1") do
      env = transport(env: { "TEST_API_KEY" => "test-key-explicit" }).send(:spawn_env)

      assert_equal "test-key-explicit", env["TEST_API_KEY"]
    end
  end

  def test_inherit_env_coercion_treats_only_false_as_opt_out
    assert_equal true, transport(inherit_env: true).inherit_env
    assert_equal true, transport(inherit_env: nil).inherit_env
    assert_equal false, transport(inherit_env: false).inherit_env
    assert_equal false, transport(inherit_env: "false").inherit_env
    # Unknown types coerce to the safe inheriting default.
    assert_equal true, transport(inherit_env: "yes").inherit_env
    assert_equal true, transport(inherit_env: 0).inherit_env
  end

  private

  def transport(env: {}, inherit_env: true)
    Rubik::MCP::Transport::Stdio.new("noop", env: env, inherit_env: inherit_env, root_dir: Dir.pwd)
  end

  def with_env(overrides)
    saved = overrides.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
