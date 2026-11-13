# frozen_string_literal: true

require_relative "../test_helper"

# MCP stdio transports must not leak the host's bundler/Ruby runtime
# environment into server subprocesses: a foreign BUNDLE_GEMFILE or RUBYOPT
# in the child changes what the server loads. The scrub list is single-homed
# in Platform.sanitized_spawn_env (the same one the LSP client applies), and
# explicitly configured env: entries merge on top and win.
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

  private

  def transport(env:)
    Rubik::MCP::Transport::Stdio.new("noop", env: env, root_dir: Dir.pwd)
  end

  def with_env(overrides)
    saved = overrides.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
