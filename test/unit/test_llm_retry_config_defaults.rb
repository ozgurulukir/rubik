# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/config"
require_relative "../../lib/rubik/llm/client"
require_relative "../../lib/rubik/orchestrator/loop"
require_relative "../../lib/rubik/orchestrator/subagent/step_runner"

# The llm.* transport-resilience knobs: one source of truth in config, typed
# validation, and end-to-end forwarding to HTTPClient.post_json.
class TestLLMRetryConfigDefaults < Minitest::Test
  RETRY_KEYS = {
    "max_retries" => 2,
    "max_429_retries" => 5,
    "backoff_base" => 0.2,
    "max_wall_clock" => 120,
    "rate_limit_max_delay" => 60
  }.freeze

  FakeResponse = Struct.new(:code, :body) do
    def initialize(code, body, headers = {})
      super(code, body)
      @headers = headers
    end

    def key?(name) = @headers.key?(name)
    def [](name) = @headers[name]
  end

  class ScriptedHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses.dup
      @requests = 0
    end

    def request(_req)
      @requests += 1
      @responses.size > 1 ? @responses.shift : @responses.first
    end
  end

  def test_defaults_expose_all_retry_knobs
    llm = Rubik::Config::Defaults::DEFAULT_CONFIG["llm"]
    RETRY_KEYS.each do |key, expected|
      assert_equal expected, llm[key], "llm.#{key} default"
    end
    assert_equal RETRY_KEYS, Rubik::Config::Defaults::LLM_RETRY_DEFAULTS
  end

  def test_schema_validates_retry_knobs
    RETRY_KEYS.each_key do |key|
      assert Rubik::Config::Schema::DEFINITIONS.key?("llm.#{key}"), "llm.#{key} has a schema entry"
    end

    assert_raises(ArgumentError) { Rubik::Config::Schema.validate_value!("llm.max_retries", -1, strict: true) }
    assert_raises(ArgumentError) { Rubik::Config::Schema.validate_value!("llm.max_429_retries", "many", strict: true) }
    assert_raises(ArgumentError) { Rubik::Config::Schema.validate_value!("llm.backoff_base", -0.1, strict: true) }
    assert_raises(ArgumentError) { Rubik::Config::Schema.validate_value!("llm.max_wall_clock", -5, strict: true) }
    assert_raises(ArgumentError) { Rubik::Config::Schema.validate_value!("llm.rate_limit_max_delay", -1, strict: true) }

    # Zero disables a budget; floats are accepted for the backoff base.
    assert Rubik::Config::Schema.validate_value!("llm.max_retries", 0, strict: true)
    assert Rubik::Config::Schema.validate_value!("llm.backoff_base", 0.35, strict: true)
  end

  def test_config_set_coerces_retry_knobs_without_disk_write
    config = Rubik::Config.new(root_dir: Dir.mktmpdir("rubik_retry_cfg"))
    assert config.set("llm.max_retries", "7", persist: nil)[:ok]
    assert_equal 7, config.fetch("llm.max_retries")
    assert config.set("llm.backoff_base", "0.35", persist: nil)[:ok]
    assert_equal 0.35, config.fetch("llm.backoff_base")
  end

  def test_retry_opts_from_forwards_only_present_keys
    opts = { max_retries: 3, on_retry: -> {}, backoff_base: nil, max_wall_clock: 0 }
    assert_equal({ max_retries: 3, max_wall_clock: 0 }, Rubik::LLM::HTTPClient.retry_opts_from(opts))
  end

  def test_retry_delay_after_respects_custom_max_delay
    res = FakeResponse.new(429, "slow", { "Retry-After" => "9999" })
    assert_equal 7, Rubik::LLM::HTTPClient.retry_delay_after(res, 1, 0.2, max_delay: 7)
  end

  def test_post_json_forwards_custom_rate_limit_delay_into_sleep
    http = ScriptedHttp.new([
                              FakeResponse.new(429, "slow", { "Retry-After" => "9999" }),
                              FakeResponse.new(200, '{"ok":true}')
                            ])
    sleeps = []
    Rubik::LLM::HTTPClient.stub(:sleep, ->(delay) { sleeps << delay }) do
      result = Rubik::LLM::HTTPClient.post_json(
        "http://127.0.0.1:1/v1/chat",
        payload: {}, backoff_base: 0, http_factory: ->(_uri) { http },
        max_429_retries: 1, rate_limit_max_delay: 4
      )
      assert_equal({ "ok" => true }, result)
    end
    assert_equal [4], sleeps
    assert_equal 2, http.requests
  end

  def build_loop(config)
    shell_struct = Struct.new(:config, :buffer_manager, :snapshot_store, :context_index, :lsp_manager, :runtime_manager, :commands)
    shell = shell_struct.new(config, nil, nil, nil, nil, nil, nil)
    registry = Struct.new(:schemas).new([])
    registry.define_singleton_method(:get) { |_name| nil }
    Rubik::Orchestrator::Loop.new(
      provider: @provider, tool_registry: registry, max_steps: 1, shell: shell
    )
  end

  def capture_provider_opts
    @provider = Object.new
    @provider.define_singleton_method(:complete) do |_history, opts = {}|
      @captured_opts = opts
      raise Rubik::LLM::ClientError, "stop"
    end
  end

  def test_root_loop_wires_retry_config_into_provider_opts
    capture_provider_opts
    config = { "llm" => {
      "max_retries" => 9, "max_429_retries" => 8, "backoff_base" => 0.3,
      "max_wall_clock" => 45, "rate_limit_max_delay" => 12
    } }

    assert_raises(Rubik::LLM::ClientError) { build_loop(config).run("task") }
    RETRY_KEYS.each_key do |key|
      assert_equal config["llm"][key], @provider.instance_variable_get(:@captured_opts)[key.to_sym], "#{key} reached provider opts"
    end
  end

  def test_root_loop_uses_fallbacks_when_config_is_absent
    capture_provider_opts
    assert_raises(Rubik::LLM::ClientError) { build_loop(nil).run("task") }
    RETRY_KEYS.each do |key, expected|
      assert_equal expected, @provider.instance_variable_get(:@captured_opts)[key.to_sym], "#{key} fallback"
    end
  end

  def test_subagent_step_runner_wires_retry_config
    host = Object.new
    host.extend(Rubik::Orchestrator::Subagent::StepRunner)
    config = { "llm" => { "max_retries" => 6 } }
    seen = nil
    provider = Object.new
    provider.define_singleton_method(:complete) do |_history, opts = {}|
      seen = opts
      :done
    end
    operations = Object.new
    operations.define_singleton_method(:start) { |*_args| }
    operations.define_singleton_method(:finish) { |*_args| }
    host.instance_variable_set(:@config, config)
    host.instance_variable_set(:@provider, provider)
    host.instance_variable_set(:@history, [])
    host.instance_variable_set(:@model, nil)
    host.instance_variable_set(:@context_limit, nil)
    host.instance_variable_set(:@max_output_tokens, nil)
    host.instance_variable_set(:@operations, operations)

    host.invoke_provider({})

    assert_equal 6, seen[:max_retries]
    assert_equal 5, seen[:max_429_retries], "unset keys fall back to the shared defaults"
  end

  # ── providers.<name>.session_header on the subagent lane ──────────────
  # Subagents are the SAME conversation for the gateway: identity comes from
  # the shell coeffect (parent-chain walk), not a per-subagent mint.

  def build_subagent_host(config:, provider:, context:)
    host = Object.new
    host.extend(Rubik::Orchestrator::Subagent::StepRunner)
    operations = Object.new
    operations.define_singleton_method(:start) { |*_args| }
    operations.define_singleton_method(:finish) { |*_args| }
    host.instance_variable_set(:@config, config)
    host.instance_variable_set(:@provider, provider)
    host.instance_variable_set(:@history, [])
    host.instance_variable_set(:@model, nil)
    host.instance_variable_set(:@context_limit, nil)
    host.instance_variable_set(:@max_output_tokens, nil)
    host.instance_variable_set(:@operations, operations)
    host.instance_variable_set(:@context, context)
    host
  end

  def test_subagent_step_runner_injects_session_header_from_shell_coeffect
    config = { "providers" => { "opencode-go" => { "session_header" => "x-opencode-session" } } }
    seen = nil
    provider = Object.new
    provider.define_singleton_method(:name) { "opencode-go" }
    provider.define_singleton_method(:complete) do |_history, opts = {}|
      seen = opts
      :done
    end
    shell = Struct.new(:recorder).new(Struct.new(:session_file).new("/t/s/session_sub.jsonl"))
    context = Object.new
    context.define_singleton_method(:get) { |key| key == Rubik::Coeffects::SHELL ? shell : nil }

    host = build_subagent_host(config: config, provider: provider, context: context)
    host.invoke_provider({})

    assert_equal Rubik::LLM::SessionHeader.uuid_for("session_sub"),
                 seen[:headers]["x-opencode-session"]
  end

  def test_subagent_step_runner_leaves_headers_absent_without_identity
    config = { "providers" => { "opencode-go" => { "session_header" => "x-opencode-session" } } }
    seen = nil
    provider = Object.new
    provider.define_singleton_method(:name) { "opencode-go" }
    provider.define_singleton_method(:complete) do |_history, opts = {}|
      seen = opts
      :done
    end
    context = Object.new
    context.define_singleton_method(:get) { |_key| nil } # shell coeffect unsatisfied

    host = build_subagent_host(config: config, provider: provider, context: context)
    host.invoke_provider({})

    refute seen.key?(:headers), "identity missing -> no header (key-absent discipline)"
  end

  # The subagent lane resolves retry knobs through ProviderResolver, so
  # provider-scoped overrides reach it exactly like the root loop.
  def test_subagent_retry_knobs_honor_provider_scoped_overrides
    config = { "llm" => { "max_retries" => 2 },
               "providers" => { "opencode-go" => { "max_retries" => 9 } } }
    seen = nil
    provider = Object.new
    provider.define_singleton_method(:name) { "opencode-go" }
    provider.define_singleton_method(:complete) do |_history, opts = {}|
      seen = opts
      :done
    end
    context = Object.new
    context.define_singleton_method(:get) { |_key| nil }

    host = build_subagent_host(config: config, provider: provider, context: context)
    host.invoke_provider({})

    assert_equal 9, seen[:max_retries], "providers.<key>.max_retries reaches the subagent lane (root parity)"
    assert_equal 5, seen[:max_429_retries], "unset provider key falls back to the global default"
  end
end
