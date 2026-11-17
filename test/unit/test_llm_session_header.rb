# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/session_header"
require "rubik/session/recorder"
require "rubik/config"

class TestLLMSessionHeader < Minitest::Test
  KNOB = "x-opencode-session"

  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  # ── uuid_for (pure derivation) ─────────────────────────────────────────

  def test_uuid_for_is_deterministic_and_uuid_shaped
    a = Rubik::LLM::SessionHeader.uuid_for("session_20261117_100000_123_456")
    b = Rubik::LLM::SessionHeader.uuid_for("session_20261117_100000_123_456")
    assert_equal a, b
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, a)
  end

  def test_uuid_for_stamps_version_and_variant_bits
    uuid = Rubik::LLM::SessionHeader.uuid_for("k")
    assert_equal "5", uuid[14], "version nibble (third group) must read 5"
    assert_includes ["8", "9", "a", "b"], uuid[19], "first nibble of the fourth group must be the RFC variant"
  end

  def test_uuid_for_distinct_keys_yield_distinct_uuids
    refute_equal Rubik::LLM::SessionHeader.uuid_for("session_a"),
                 Rubik::LLM::SessionHeader.uuid_for("session_b")
  end

  def test_uuid_for_blank_identity_is_nil
    assert_nil Rubik::LLM::SessionHeader.uuid_for(nil)
    assert_nil Rubik::LLM::SessionHeader.uuid_for("")
  end

  # ── conversation identity ──────────────────────────────────────────────

  def test_session_key_from_recorder_tracks_switch_session_file
    recorder = Rubik::Session::Recorder.new(sessions_dir: @temp_dir, session_name: "session_x.jsonl")
    assert_equal "session_x", Rubik::LLM::SessionHeader.session_key_from_recorder(recorder)

    # Resume re-targets the SAME file; a different file is a different
    # conversation id (recorder switch_session_file contract).
    other = File.join(@temp_dir, "session_y.jsonl")
    recorder.switch_session_file(other)
    assert_equal "session_y", Rubik::LLM::SessionHeader.session_key_from_recorder(recorder)
  end

  def test_session_key_from_recorder_is_nil_safe
    assert_nil Rubik::LLM::SessionHeader.session_key_from_recorder(nil)
    assert_nil Rubik::LLM::SessionHeader.session_key_from_recorder(Object.new)
  end

  # Recorder#session_id is the SSOT for the basename spelling; the header
  # derivation must follow it (and the file, live, across switch_session_file).
  def test_recorder_session_id_is_the_identity_ssot
    recorder = Rubik::Session::Recorder.new(sessions_dir: @temp_dir, session_name: "session_x.jsonl")
    assert_equal "session_x", recorder.session_id
    assert_equal recorder.session_id, Rubik::LLM::SessionHeader.session_key_from_recorder(recorder)
  end

  def test_session_key_from_context_reads_the_shell_coeffect
    recorder = Rubik::Session::Recorder.new(sessions_dir: @temp_dir, session_name: "session_x.jsonl")
    shell = Struct.new(:recorder).new(recorder)
    ctx = Object.new
    ctx.define_singleton_method(:get) { |key| key == Rubik::Coeffects::SHELL ? shell : nil }

    assert_equal "session_x", Rubik::LLM::SessionHeader.session_key_from_context(ctx)
  end

  def test_session_key_from_context_is_nil_safe
    assert_nil Rubik::LLM::SessionHeader.session_key_from_context(nil)
    assert_nil Rubik::LLM::SessionHeader.session_key_from_context(Object.new) # no #get
    empty_ctx = Object.new
    empty_ctx.define_singleton_method(:get) { |_key| nil } # coeffect unsatisfied
    assert_nil Rubik::LLM::SessionHeader.session_key_from_context(empty_ctx)
  end

  # ── knob resolution ────────────────────────────────────────────────────

  def test_header_name_resolves_provider_scoped_knob
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.opencode-go.session_header", KNOB)
    assert_equal KNOB, Rubik::LLM::SessionHeader.header_name(cfg, "opencode-go")
  end

  def test_header_name_missing_blank_or_degenerate_inputs_are_nil
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_nil Rubik::LLM::SessionHeader.header_name(cfg, "opencode-go")
    assert_nil Rubik::LLM::SessionHeader.header_name(cfg, "")
    assert_nil Rubik::LLM::SessionHeader.header_name(cfg, nil)
    assert_nil Rubik::LLM::SessionHeader.header_name(nil, "opencode-go")
  end

  def test_header_name_accepts_plain_hash_config
    config = { "providers" => { "p" => { "session_header" => "x-ses" } } }
    assert_equal "x-ses", Rubik::LLM::SessionHeader.header_name(config, "p")
  end

  # ── explicit-beats-automatic scopes ────────────────────────────────────

  def test_explicit_header_names_union_scoped_and_global_downcased
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.headers", { "X-A" => "1" })
    cfg.set("llm.headers", { "X-B" => "2" })
    assert_equal ["x-a", "x-b"], Rubik::LLM::SessionHeader.explicit_header_names(cfg, "p")
  end

  def test_explicit_header_names_without_config_entries_is_empty
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_empty Rubik::LLM::SessionHeader.explicit_header_names(cfg, "p")
    assert_empty Rubik::LLM::SessionHeader.explicit_header_names(nil, "p")
  end

  # ── apply! (the injection core) ────────────────────────────────────────

  def test_apply_injects_derived_uuid
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    opts = {}

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: "session_x")

    assert_equal Rubik::LLM::SessionHeader.uuid_for("session_x"), opts[:headers][KNOB]
  end

  def test_apply_merges_alongside_existing_call_headers
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    opts = { headers: { "X-Keep" => "keep" } }

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: "session_x")

    assert_equal "keep", opts[:headers]["X-Keep"]
    assert_equal Rubik::LLM::SessionHeader.uuid_for("session_x"), opts[:headers][KNOB]
  end

  def test_apply_leaves_headers_absent_when_knob_unset
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    opts = {}

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: "session_x")

    refute opts.key?(:headers)
  end

  def test_apply_leaves_headers_absent_when_identity_missing
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    opts = {}

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: nil)

    refute opts.key?(:headers)
  end

  # A set knob with an unresolvable identity is a standing misconfiguration
  # (the gateway will hard-400 mid-conversation) — the honest channel is a
  # Log.warn, not a debug_warn no-op.
  def test_apply_warns_when_knob_set_but_identity_missing
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    warned = []
    opts = {}

    Rubik::Log.stub(:warn, ->(channel, msg) { warned << [channel, msg] }) do
      Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: nil)
    end

    refute opts.key?(:headers)
    assert_equal 1, warned.size
    assert_includes warned[0][1], "session_header"
  end

  def test_apply_skips_when_explicit_scoped_header_owns_the_name
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    cfg.set("providers.p.headers", { KNOB => "manual" })
    opts = {}

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: "session_x")

    refute opts.key?(:headers), "explicit static value wins: no auto-injection"
  end

  def test_apply_skips_when_explicit_global_header_owns_the_name_case_insensitively
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    cfg.set("llm.headers", { "X-Opencode-Session" => "manual" })
    opts = {}

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: "session_x")

    refute opts.key?(:headers), "case-differing explicit global header still suppresses"
  end

  def test_apply_skips_when_caller_opts_already_own_the_name
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.p.session_header", KNOB)
    opts = { headers: { "X-OPENCODE-SESSION" => "caller" } }

    Rubik::LLM::SessionHeader.apply!(opts, provider_key: "p", config: cfg, session_key: "session_x")

    assert_equal "caller", opts[:headers]["X-OPENCODE-SESSION"], "per-call opts merge LAST in adapters"
    refute_includes opts[:headers].values, Rubik::LLM::SessionHeader.uuid_for("session_x")
  end
end
