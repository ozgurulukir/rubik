# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/scripted_connect_prompt"
require "rubik/cli/connect"

class TestConnectCli < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_cli_root")
    @home = Dir.mktmpdir("rubik_cli_home")
    @out = StringIO.new
    seed_catalog_cache
  end

  def teardown
    begin
      FileUtils.remove_entry(@root)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@home)
    rescue
      nil
    end
  end

  # Pre-warms the models.dev cache inside the test home so the CLI test
  # never touches the network (and runs in milliseconds instead of the
  # multi-second live fetch).
  def seed_catalog_cache
    path = Rubik::Connect::ModelsDev.cache_path(@home)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate({ "fetched_at" => Time.now.to_i,
                                     "providers" => { "openai" => { "api" => "https://api.openai.com/v1",
                                                                    "name" => "OpenAI",
                                                                    "models" => { "gpt-x" => { "limit" => { "context" => 400_000 },
                                                                                               "tool_call" => true } } } } }))
  end

  def scripted(answers)
    ScriptedConnectPrompt.new(answers)
  end

  def test_non_interactive_stdin_exits_2_with_honest_guidance
    code = Rubik::CLI::Connect.run(argv: [], input: StringIO.new, output: @out,
                                   root_dir: @root, home_dir: @home)

    assert_equal 2, code
    assert_includes @out.string, "Non-interactive session"
    assert_includes @out.string, "!provider add"
  end

  def test_happy_path_exits_0_and_persists_provider
    ui = scripted([
                    ->(_k, _q, choices, _d) { choices.find { |c| c.include?("OpenAI") } },
                    ->(_k, _q, _c, d) { d },
                    ->(_k, _q, choices, _d) { choices.find { |c| c.include?("API anahtarı") } },
                    ->(*_args) { "fake-cli-key" },
                    ->(_k, _q, choices, _d) { choices.first },
                    ->(_k, _q, choices, _d) { choices.find { |c| c.include?("Sadece default") } },
                    ->(*_args) { true }
                  ])
    probe = Class.new do
      def openai_compatible(_base, *_args, **_kwargs)
        { ok: true, auth_failed: false, reachable: true, models: ["gpt-live"] }
      end
    end.new

    code = Rubik::CLI::Connect.run(argv: [], input: StringIO.new, output: @out,
                                   root_dir: @root, home_dir: @home, prompt: ui, probe: probe)

    assert_equal 0, code
    config = Rubik::Config.new(root_dir: @root, home_dir: @home)
    spec = config.provider_spec("openai")
    refute_nil spec
    assert_equal "openai_compatible", spec["type"]
    assert spec["api_key"].start_with?("rubik-secret:")
    assert_equal "gpt-live", config.fetch("models.default")["name"]
    assert_includes @out.string, "rubik'"
  end

  def test_cancelled_flow_exits_1_and_writes_nothing
    ui = scripted([->(*_args) { :cancelled }])
    probe = Class.new do
      def openai_compatible(*, **)
        raise "probes must not run for a cancelled flow"
      end
    end.new

    code = Rubik::CLI::Connect.run(argv: [], input: StringIO.new, output: @out,
                                   root_dir: @root, home_dir: @home, prompt: ui, probe: probe)

    assert_equal 1, code
    config = Rubik::Config.new(root_dir: @root, home_dir: @home)
    assert_empty config.fetch("providers", {})
  end

  def test_project_flag_refuses_plaintext_secret_persist
    # A --project run with a plaintext key must be refused by SecretPolicy:
    # exit 1, no provider written, and the refusal reason surfaced.
    ui2 = ScriptedConnectPrompt.new([
                                      ->(_k, _q, choices, _d) { choices.find { |c| c.include?("OpenAI") } },
                                      ->(_k, _q, _c, d) { d },
                                      ->(_k, _q, choices, _d) { choices.find { |c| c.include?("API anahtarı") } },
                                      ->(*_args) { "project-key" },
                                      ->(_k, _q, choices, _d) { choices.first },
                                      ->(_k, _q, choices, _d) { choices.find { |c| c.include?("Sadece default") } },
                                      ->(*_args) { true }
                                    ])
    probe = Class.new do
      def openai_compatible(*, **)
        { ok: true, auth_failed: false, reachable: true, models: ["m"] }
      end
    end.new

    code = Rubik::CLI::Connect.run(argv: ["--project"], input: StringIO.new, output: @out,
                                   root_dir: @root, home_dir: @home, prompt: ui2, probe: probe)

    assert_equal 1, code
    config = Rubik::Config.new(root_dir: @root, home_dir: @home)
    assert_nil config.provider_spec("openai")
    assert_includes @out.string, "Could not save"
  end

  def test_help_flag_prints_usage_and_exits_zero
    code = Rubik::CLI::Connect.run(argv: ["--help"], input: StringIO.new, output: @out,
                                   root_dir: @root, home_dir: @home)

    assert_equal 0, code
    assert_includes @out.string, "Usage: rubik connect"
  end

  def test_session_flag_refused_with_exit_one
    code = Rubik::CLI::Connect.run(argv: ["--session"], input: StringIO.new, output: @out,
                                   root_dir: @root, home_dir: @home)

    assert_equal 1, code
    assert_includes @out.string, "!provider add"
  end
end
