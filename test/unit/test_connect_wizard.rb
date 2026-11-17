# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/scripted_connect_prompt"
require "rubik/connect"
require "rubik/config"

class TestConnectWizard < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_wiz_root")
    @home = Dir.mktmpdir("rubik_wiz_home")
    @config = Rubik::Config.new(root_dir: @root, home_dir: @home)
    @catalog = {
      "openai" => { "api" => "https://api.openai.com/v1", "name" => "OpenAI",
                    "models" => { "gpt-x" => { "limit" => { "context" => 400_000 }, "tool_call" => true } } },
      "anthropic" => { "api" => nil, "name" => "Anthropic",
                       "models" => { "claude-x" => { "limit" => { "context" => 200_000 }, "tool_call" => true } } }
    }
    @probe = WizardProbeStub.new
    @out_io = StringIO.new
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

  # Probes stub: the wizard must never touch the network in tests.
  class WizardProbeStub
    attr_reader :calls

    def initialize
      @calls = []
      @results = []
    end

    def queue(result)
      @results << result
    end

    def openai_compatible(_base, api_key: nil, **_kwargs)
      @calls << [:openai_compatible, api_key]
      @results.shift || { ok: true, auth_failed: false, reachable: true, models: ["model-a", "model-b"] }
    end

    def anthropic(api_key: nil, **_kwargs)
      @calls << [:anthropic, api_key]
      @results.shift || { ok: true, auth_failed: false, reachable: true, models: ["claude-x"] }
    end

    def ollama(_host, **_kwargs)
      @calls << [:ollama]
      @results.shift || { ok: true, auth_failed: false, reachable: true, models: ["qwen:7b"] }
    end
  end

  def wizard(ui, io: StringIO.new, scope: :global)
    Rubik::Connect::Wizard.new(config: @config, ui: ui, io: io, scope: scope,
                               catalog_loader: -> { { catalog: @catalog, source: :cache } },
                               probe: @probe)
  end

  def pick(matcher)
    ->(_kind, _q, choices, _default) { choices.find { |c| c.include?(matcher) } || choices.first }
  end

  def accept_default
    ->(_kind, _q, _choices, default) { default }
  end

  def literal(value)
    ->(*_args) { value }
  end

  # ── happy paths ──────────────────────────────────────────────────────

  def test_openai_compatible_happy_path_writes_provider_and_default_role
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"), # provider
                                     accept_default,          # endpoint (catalog api accepted)
                                     pick("Hayır"),           # session header: not required
                                     pick("API anahtarı"),    # auth: enter key
                                     literal("fake-key-value-1"), # secret
                                     pick("model-a"),         # model (live list)
                                     pick("Sadece default"),  # roles
                                     literal(true)            # confirm
                                   ])
    res = wizard(ui).run

    assert res[:ok], "expected ok, got #{res.inspect}"
    assert_equal "openai", res[:provider]
    assert_equal "model-a", res[:model]
    assert_equal ["default"], res[:roles]

    spec = @config.provider_spec("openai")
    refute_nil spec
    assert_equal "openai_compatible", spec["type"]
    assert_equal "https://api.openai.com/v1/chat/completions", spec["endpoint"]
    assert_equal [{ "name" => "model-a", "context_limit" => 32_768 }], spec["models"]
    # SecretPolicy routed the key into the OS secret store (file backend
    # under RUBIK_TEST); the config holds only the pointer.
    assert spec["api_key"].start_with?("rubik-secret:"), "expected pointer, got #{spec['api_key'].inspect}"
    refute_includes File.read(@config.global_config_path), "fake-key-value-1"

    role = @config.fetch("models.default")
    assert_equal "openai", role["provider"]
    assert_equal "model-a", role["name"]
    assert_equal "https://api.openai.com/v1", role["endpoint"]
  end

  def test_anthropic_happy_path
    # No endpoint question for anthropic: AnthropicProvider honors no
    # endpoint parameter, so the wizard locks the base silently.
    ui = ScriptedConnectPrompt.new([
                                     pick("Anthropic"),
                                     pick("API anahtarı"),
                                     literal("fake-key-value-2"),
                                     pick("claude-x"),
                                     pick("default + fast + advanced"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    spec = @config.provider_spec("anthropic")
    assert_equal "anthropic", spec["type"]
    assert_equal "https://api.anthropic.com", spec["endpoint"]
    assert_equal [{ "name" => "claude-x", "context_limit" => 200_000 }], spec["models"]
    role = @config.fetch("models.advanced")
    assert_equal "anthropic", role["provider"]
    assert_equal "claude-x", role["name"]
  end

  def test_ollama_happy_path_uses_live_tag_list_and_skips_key
    ui = ScriptedConnectPrompt.new([
                                     pick("Ollama"),
                                     accept_default, # endpoint
                                     # no auth question for ollama
                                     pick("qwen:7b"), # model from live /api/tags
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    assert_equal [:ollama], @probe.calls.map(&:first)
    spec = @config.provider_spec("ollama")
    assert_equal "ollama", spec["type"]
    assert_equal "http://localhost:11434", spec["endpoint"]
    refute spec.key?("api_key")
    role = @config.fetch("models.default")
    assert_equal "ollama", role["provider"]
    assert_equal "qwen:7b", role["name"]
  end

  def test_custom_provider_manual_model_and_context
    ui = ScriptedConnectPrompt.new([
                                     pick("Özel uç nokta"), # custom branch
                                     literal("My Gateway"),                        # provider name
                                     pick("openai_compatible"),                    # type
                                     literal("http://localhost:8000"),             # endpoint
                                     pick("Hayır"),                                # session header: not required
                                     pick("Şimdilik atla"),                        # auth: skip
                                     pick("✎ Elle gir"),                           # manual model
                                     literal("llama3"),                            # model name
                                     literal("16384"),                             # context limit
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui, io: StringIO.new).run

    assert res[:ok], res.inspect
    spec = @config.provider_spec("my-gateway")
    refute_nil spec
    assert_equal "openai_compatible", spec["type"]
    assert_equal "http://localhost:8000/v1/chat/completions", spec["endpoint"]
    assert_equal [{ "name" => "llama3", "context_limit" => 16_384 }], spec["models"]
  end

  def test_all_catalog_submenu_picks_groq
    @catalog["groq"] = { "api" => "https://api.groq.com/openai/v1", "name" => "Groq",
                         "models" => { "llama-fast" => { "limit" => { "context" => 131_072 }, "tool_call" => true } } }
    ui = ScriptedConnectPrompt.new([
                                     pick("Tüm katalog"), # all-catalog submenu
                                     pick("Groq"),             # inside submenu
                                     accept_default,           # endpoint
                                     pick("Hayır"),            # session header: not required
                                     pick("Şimdilik atla"),    # auth skip
                                     pick("llama-fast"),       # catalog model (context-annotated label)
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    spec = @config.provider_spec("groq")
    assert_equal "https://api.groq.com/openai/v1/chat/completions", spec["endpoint"]
    # context limit came from the catalog's limit.context
    assert_equal [{ "name" => "llama-fast", "context_limit" => 131_072 }], spec["models"]
  end

  # ── validation loop ──────────────────────────────────────────────────

  def test_auth_failure_reasks_then_saves
    @probe.queue({ ok: false, auth_failed: true, reachable: true, models: [], note: "HTTP 401 — key rejected" })
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Hayır"),
                                     pick("API anahtarı"),
                                     literal("wrong-key"),                          # first attempt
                                     pick("yeniden gir"),                           # failure menu: re-enter
                                     literal("good-key"),                           # second attempt
                                     pick("model-a"),
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    assert_equal 2, @probe.calls.size # probed twice, saved on the good key
  end

  def test_unreachable_endpoint_save_anyway
    @probe.queue({ ok: false, auth_failed: false, reachable: false, models: [], note: "connection refused" })
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Hayır"),
                                     pick("API anahtarı"),
                                     literal("offline-key"),
                                     pick("Yine de kaydet"),                        # save without validation
                                     pick("gpt-x"),                                 # catalog menu (probe failed)
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    assert(res[:notes].any? { |n| n.include?("connection refused") })
    spec = @config.provider_spec("openai")
    assert spec["api_key"].start_with?("rubik-secret:")
  end

  def test_empty_key_entry_defers_validation
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Hayır"),
                                     pick("API anahtarı"),
                                     literal(""),                                   # empty = defer
                                     pick("gpt-x"),                                 # catalog menu (no probe ran)
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    spec = @config.provider_spec("openai")
    refute spec.key?("api_key") # compact dropped the nil key
    assert(res[:notes].any? { |n| n.include?("key deferred") })
  end

  def test_probe_attempts_exhausted_saves_last_key
    5.times { @probe.queue({ ok: false, auth_failed: true, reachable: true, models: [], note: "HTTP 401" }) }
    answers = [pick("OpenAI"), accept_default, pick("Hayır"), pick("API anahtarı")]
    5.times do
      answers << literal("retry-key")
      answers << pick("yeniden gir")
    end
    answers << pick("gpt-x") # catalog model menu (live list absent)
    answers << pick("Sadece default")
    answers << literal(true)
    ui = ScriptedConnectPrompt.new(answers)
    res = wizard(ui).run

    assert res[:ok]
    assert_equal 5, @probe.calls.size
    assert(res[:notes].any? { |n| n.include?("attempts exhausted") })
  end

  # ── cancellation safety ─────────────────────────────────────────────

  def test_cancel_mid_flow_writes_nothing
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Hayır"),
                                     pick("API anahtarı"),
                                     literal(:cancelled) # Ctrl+C at the key prompt
                                   ])
    res = wizard(ui).run

    refute res[:ok]
    assert_equal :cancelled, res[:reason]
    assert_nil @config.provider_spec("openai")
    assert_equal({ "provider" => "ollama", "name" => "qwen2.5-coder:7b", "endpoint" => "http://localhost:11434" },
                 @config.fetch("models.default"))
    assert(ui.printed.any? { |l| l.include?("hiçbir şey yazılmadı") })
  end

  def test_non_interactive_returns_before_any_question
    ui = ScriptedConnectPrompt.new([])
    ui.define_singleton_method(:interactive?) { false }
    res = wizard(ui).run

    refute res[:ok]
    assert_equal :non_interactive, res[:reason]
    assert_empty @probe.calls
    # nothing was printed — not even the header frame
    assert_empty ui.printed
  end

  # ── scope + write failure ────────────────────────────────────────────

  def test_project_scope_write_refused_by_secret_policy
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Hayır"),
                                     pick("API anahtarı"),
                                     literal("plaintext-for-project"),
                                     pick("model-a"),
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui, scope: :project).run

    refute res[:ok]
    assert_equal :write_failed, res[:reason]
    assert res[:error].is_a?(String)
    # the honest failure names the escape hatches
    assert res[:error].include?("security.allow_project_secrets")
  end

  def test_session_scope_is_not_used_by_wizard_but_global_is_default
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"), accept_default, pick("Hayır"), pick("API anahtarı"), literal("key-session"),
                                     pick("model-a"), pick("Sadece default"), literal(true)
                                   ])
    res = wizard(ui, scope: :global).run

    assert res[:ok]
    assert_equal :global, res[:scope]
    assert File.exist?(@config.global_config_path)
  end

  def test_catalog_unavailable_manual_mode_still_works
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"), # pinned fallback base used (offline defaults)
                                     accept_default,          # endpoint
                                     pick("Hayır"),           # session header: not required
                                     pick("Şimdilik atla"),   # auth skip
                                     pick("✎ Elle gir"),      # manual model
                                     literal("manual-model"),
                                     literal("8192"),
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run
    assert res[:ok]

    # now with a completely empty catalog + :none source
    empty_ui = ScriptedConnectPrompt.new([
                                           pick("Ollama"), accept_default, pick("qwen:7b"), pick("Sadece default"), literal(true)
                                         ])
    io = StringIO.new
    wiz = Rubik::Connect::Wizard.new(config: @config, ui: empty_ui, io: io, scope: :global,
                                     catalog_loader: -> { { catalog: {}, source: :none } },
                                     probe: @probe)
    res2 = wiz.run
    assert res2[:ok]
    assert(res2[:notes].any? { |n| n.include?("manual mode") })
    assert_includes io.string, "manual mode"
  end

  def test_manual_context_limit_accepts_k_and_m_suffixes
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"), accept_default, pick("Hayır"), pick("Şimdilik atla"),
                                     pick("✎ Elle gir"),
                                     literal("manual-model"), # name
                                     literal("200k"),         # context limit with suffix
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    assert_equal 200_000, @config.provider_spec("openai")["models"].first["context_limit"]
  end

  # ── session header (issue #533) ─────────────────────────────────────

  def test_session_header_collected_and_persisted_on_yes
    io = StringIO.new
    ui = ScriptedConnectPrompt.new([
                                     pick("Özel uç nokta"),                                        # custom branch
                                     literal("opencode"),                                          # provider name
                                     pick("openai_compatible"),                                    # type
                                     literal("https://opencode.ai/inference/go/openai/v1"),        # endpoint (Go gateway)
                                     pick("Evet"),                                                 # session header: yes
                                     literal("x-opencode-session"),                                # header name
                                     pick("API anahtarı"),                                         # auth: enter key
                                     literal("fake-opencode-key"),                                 # secret
                                     pick("model-a"),                                              # model (live list)
                                     pick("Sadece default"),                                       # roles
                                     literal(true)                                                 # confirm
                                   ])
    res = wizard(ui, io: io).run

    assert res[:ok], res.inspect
    spec = @config.provider_spec("opencode")
    refute_nil spec
    assert_equal "x-opencode-session", spec["session_header"]
    # The Go gateway base carries the /v1 tail, so the spec spells the
    # POSTable /v1/chat/completions path.
    assert_equal "https://opencode.ai/inference/go/openai/v1/chat/completions", spec["endpoint"]
    # The confirm summary names the header before the user commits.
    assert_includes io.string, "Oturum / Session header"
    assert_includes io.string, "x-opencode-session"
  end

  def test_session_header_no_path_keeps_key_absent
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Hayır"), # session header: not required
                                     pick("API anahtarı"),
                                     literal("fake-no-header-key"),
                                     pick("model-a"),
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    spec = @config.provider_spec("openai")
    refute spec.key?("session_header"), "expected no session_header key, got #{spec.inspect}"
  end

  def test_session_header_name_invalid_then_valid
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Evet"),                       # session header: yes
                                     literal("bad header!"),             # invalid: space + punctuation
                                     literal("x-opencode-session"),      # valid retry
                                     pick("API anahtarı"),
                                     literal("fake-retry-key"),
                                     pick("model-a"),
                                     pick("Sadece default"),
                                     literal(true)
                                   ])
    res = wizard(ui).run

    assert res[:ok]
    assert_equal "x-opencode-session", @config.provider_spec("openai")["session_header"]
  end

  def test_cancel_at_session_header_name_prompt_writes_nothing
    ui = ScriptedConnectPrompt.new([
                                     pick("OpenAI"),
                                     accept_default,
                                     pick("Evet"),       # session header: yes
                                     literal(:cancelled) # Ctrl+C at the header-name prompt
                                   ])
    res = wizard(ui).run

    refute res[:ok]
    assert_equal :cancelled, res[:reason]
    assert_nil @config.provider_spec("openai")
  end
end
