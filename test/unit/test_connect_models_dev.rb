# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/connect/models_dev"
require "rubik/llm/openai_compatible"

class TestConnectModelsDev < Minitest::Test
  ModelsDev = Rubik::Connect::ModelsDev

  def setup
    @home = Dir.mktmpdir("rubik_connect_home")
    @now = 1_700_000_000
  end

  def teardown
    FileUtils.remove_entry(@home) if @home && File.exist?(@home)
  end

  def catalog_fixture
    {
      "groq" => { "npm" => nil, "api" => "https://api.groq.com/openai/v1", "name" => "Groq",
                  "models" => { "llama-fast" => { "limit" => { "context" => 131_072 }, "tool_call" => true },
                                "whisper" => { "limit" => { "context" => 8192 }, "tool_call" => false },
                                "unknown" => {} } },
      "anthropic" => { "npm" => "@ai-sdk/anthropic", "api" => nil, "name" => "Anthropic",
                       "models" => { "claude-x" => { "limit" => { "context" => 200_000 } } } },
      "openai" => { "npm" => "@ai-sdk/openai", "api" => "https://api.openai.com/v1", "name" => "OpenAI",
                    "models" => { "gpt-x" => { "limit" => { "context" => 400_000 }, "tool_call" => true } } },
      "vendor-x" => { "npm" => nil, "api" => "https://gateway.vendor-x.com/anthropic/v1", "name" => "VendorX" },
      "no-api" => { "npm" => nil, "api" => nil, "name" => "NoApi" }
    }
  end

  def fetcher_returning(catalog)
    ->(_uri) { { ok: true, status: 200, json: { "providers" => catalog } } }
  end

  def test_load_fresh_fetches_and_writes_cache
    res = ModelsDev.load(home_dir: @home, now: -> { @now }, fetcher: fetcher_returning(catalog_fixture))

    assert_equal :fresh, res[:source]
    assert_equal "Groq", res[:catalog]["groq"]["name"]
    assert File.exist?(ModelsDev.cache_path(@home))
    # atomic write leaves no tmp residue (pid-suffixed)
    refute Dir.glob("#{ModelsDev.cache_path(@home)}*.tmp").any?
  end

  def test_load_cache_hit_within_ttl
    ModelsDev.load(home_dir: @home, now: -> { @now }, fetcher: fetcher_returning(catalog_fixture))

    network_called = false
    fetcher = lambda { |_uri|
      network_called = true
      { ok: true, status: 200, json: { "providers" => {} } }
    }
    res = ModelsDev.load(home_dir: @home, now: -> { @now + ModelsDev::TTL_SECONDS - 1 }, fetcher: fetcher)

    assert_equal :cache, res[:source]
    refute network_called
  end

  def test_load_expired_ttl_refetches
    ModelsDev.load(home_dir: @home, now: -> { @now }, fetcher: fetcher_returning(catalog_fixture))

    res = ModelsDev.load(home_dir: @home, now: -> { @now + ModelsDev::TTL_SECONDS }, fetcher: fetcher_returning({ "fresh" => { "api" => "https://x.dev/v1", "name" => "Fresh" } }))

    assert_equal :fresh, res[:source]
    assert res[:catalog].key?("fresh")
  end

  def test_load_network_failure_falls_back_to_stale_cache
    ModelsDev.load(home_dir: @home, now: -> { @now }, fetcher: fetcher_returning(catalog_fixture))

    failing = ->(_uri) { { ok: false, error: "boom", status: nil, reason: :unreachable } }
    res = ModelsDev.load(home_dir: @home, now: -> { @now + (10 * ModelsDev::TTL_SECONDS) }, fetcher: failing)

    assert_equal :stale, res[:source]
    assert_equal "Groq", res[:catalog]["groq"]["name"]
  end

  def test_load_no_cache_no_network_yields_none
    failing = ->(_uri) { { ok: false, error: "boom", status: nil, reason: :unreachable } }
    res = ModelsDev.load(home_dir: @home, now: -> { @now }, fetcher: failing)

    assert_equal :none, res[:source]
    assert_empty res[:catalog]
  end

  def test_load_corrupt_cache_is_a_miss
    path = ModelsDev.cache_path(@home)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{not json")

    res = ModelsDev.load(home_dir: @home, now: -> { @now }, fetcher: fetcher_returning(catalog_fixture))

    assert_equal :fresh, res[:source]
  end

  def test_openai_compatible_filter
    compatible = ModelsDev.compatible_providers(catalog_fixture)
    ids = compatible.map { |p| p[:id] }

    assert_includes ids, "groq"     # api URL shape
    assert_includes ids, "openai"   # npm package
    refute_includes ids, "anthropic" # native SDK, no api
    refute_includes ids, "vendor-x"  # /anthropic/ path
    refute_includes ids, "no-api"    # nothing to prefill
  end

  def test_models_for_sorted_by_context_desc
    models = ModelsDev.models_for(catalog_fixture, "groq")

    assert_equal(["llama-fast", "whisper", "unknown"], models.map { |m| m[:id] })
    assert_equal 131_072, models.first[:context_limit]
    assert_equal true, models.first[:tool_call]
    assert_nil models[2][:context_limit]
  end

  def test_models_for_unknown_provider_is_empty
    assert_empty ModelsDev.models_for(catalog_fixture, "nope")
    assert_empty ModelsDev.models_for(nil, "groq")
  end

  def test_default_model_prefers_tool_capable_widest_context
    models = ModelsDev.models_for(catalog_fixture, "groq")

    assert_equal "llama-fast", ModelsDev.default_model(models)[:id]
    assert_nil ModelsDev.default_model([])
  end

  def test_provider_key_sanitizes
    assert_equal "openai-gmbh", ModelsDev.provider_key("OpenAI GmbH!!")
    assert_equal "groq", ModelsDev.provider_key("Groq")
    assert_equal "foo", ModelsDev.provider_key("- - foo - -")
    assert_equal "", ModelsDev.provider_key("///")
  end

  # ── pinned opencode row (issue #533) ─────────────────────────────────

  def test_pinned_opencode_row_targets_go_gateway
    row = ModelsDev::PINNED.find { |p| p[:id] == "opencode" }

    refute_nil row, "expected an opencode row in PINNED"
    assert_equal "openai_compatible", row[:type]
    assert_equal "opencode", row[:catalog_id]
    # The Go gateway base (the catalog's own api for "opencode" is the
    # console endpoint), so the pinned api must win over the catalog.
    assert_equal "https://opencode.ai/inference/go/openai/v1", row[:api]
    assert_equal false, row[:use_catalog_api]
  end

  def test_opencode_preset_base_normalizes_to_v1_chat_completions
    # Documents why the preset base carries the /v1 tail: normalize_endpoint
    # appends /chat/completions to a versioned tail, but a bare /openai tail
    # would spell /openai/chat/completions — a path the Go gateway 404s.
    base = "https://opencode.ai/inference/go/openai/v1"
    provider = Rubik::LLM::OpenAICompatibleProvider

    assert_equal "https://opencode.ai/inference/go/openai/v1/chat/completions", provider.normalize_endpoint(base)
    assert_equal "https://opencode.ai/inference/go/openai/chat/completions",
                 provider.normalize_endpoint("https://opencode.ai/inference/go/openai")
    refute_equal "#{base}/chat/completions",
                 provider.normalize_endpoint("https://opencode.ai/inference/go/openai")
  end
end
