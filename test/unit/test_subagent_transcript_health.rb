# frozen_string_literal: true

require_relative "../test_helper"
require "monitor"
require "digest"
require "json"

# Transcript sağlık paketi (2026-10-10): kalıcı subagent transcript'inde
# kurulan (assembled) system prompt yalnızca doğrulanabilir özet olarak
# yaşar — builtin archetype'tan türeyen prompt sha256 meta stub'ına iner,
# custom tip / çağıran prompt'u bire bir kopya olarak kalır (tek kayıt).
# In-memory @history her koşulda ham kalır.
class TestSubagentTranscriptHealth < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_transcript_health")
    @context = Rubik::Runtime::Context.new
  end

  def teardown
    @context&.dispose unless @context&.disposed?
    remove_temp_dir(@tmp) if File.directory?(@tmp)
  end

  def transcript_path(id)
    File.join(@tmp, ".rubik", "subagents", id, "transcript.jsonl")
  end

  def save_rows!(rows, path: transcript_path("sid-h"), prompt_reconstructible: false)
    Rubik::Orchestrator::Subagent::TranscriptFormatter.save!(path, rows, Monitor.new,
                                                             prompt_reconstructible: prompt_reconstructible)
  end

  def read_rows(path)
    File.readlines(path, encoding: "UTF-8").reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end

  def done_provider(content = "All done")
    resp = Struct.new(:content, :tool_calls).new(content, [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp }
    provider
  end

  # ------------------------------------------------------- save! sözleşmesi

  def test_builtin_prompt_serializes_as_meta_stub_with_sha256
    prompt = "You are a specialized subagent. BUILTIN-BOILERPLATE-7f3a"
    rows = [{ role: "system", content: prompt }, { role: "user", content: "do the thing" }]

    save_rows!(rows, prompt_reconstructible: true)

    parsed = read_rows(transcript_path("sid-h"))
    assert_equal 2, parsed.size, "row count is preserved"
    assert_equal "system", parsed.first["role"], "line-role contract: row 1 stays the system row"
    expected = Digest::SHA256.hexdigest(prompt)[0, 16]
    assert_equal "[assembled system prompt omitted] prompt_sha256=#{expected}", parsed.first["content"]
    refute_includes File.read(transcript_path("sid-h")), "BUILTIN-BOILERPLATE-7f3a"
    assert_equal "do the thing", parsed.last["content"], "rows after the system row pass through verbatim"
  end

  def test_save_without_the_kwarg_keeps_the_verbatim_copy
    rows = [{ role: "system", content: "GENERIC-CALLER-RECORD" }, { role: "user", content: "t" }]

    Rubik::Orchestrator::Subagent::TranscriptFormatter.save!(transcript_path("sid-g"), rows, Monitor.new)

    assert_includes File.read(transcript_path("sid-g")), "GENERIC-CALLER-RECORD",
                    "generic save! is conservative: no decision, no stub"
  end

  def test_in_memory_history_stays_raw_after_stubbed_save
    prompt = "ASSEMBLED-BASE-9c1d"
    rows = [{ role: "system", content: prompt }, { role: "user", content: "task" }]

    save_rows!(rows, prompt_reconstructible: true)

    assert_equal "system", rows.first[:role]
    assert_equal prompt, rows.first[:content], "the wire copy in memory must never mutate"
  end

  def test_first_row_stubbed_only_when_it_is_actually_the_system_row
    rows = [{ role: "user", content: "not a system row" }, { role: "assistant", content: nil, tool_calls: nil }]

    save_rows!(rows, prompt_reconstructible: true)

    parsed = read_rows(transcript_path("sid-h"))
    assert_equal "not a system row", parsed.first["content"], "a non-system first row passes through untouched"
  end

  # ---------------------------------------------------- Redaction paritesi

  def test_secret_patterns_are_masked_on_disk_and_raw_in_memory
    token = "ghp_#{'a' * 36}"
    rows = [
      { role: "system", content: "ASSEMBLED-X" },
      { role: "user", content: "deploy with #{token} now" },
      { role: "assistant", content: nil,
        tool_calls: [{ "tool" => "run_command",
                       "args" => { "command" => "export API_KEY=supersecret-value-1", "retries" => 3 } }] },
      { role: "tool", tool_call_id: "t1", tool_name: "run_command", status: :ok, duration_ms: 1.0,
        content: "echo: sk-#{'x' * 24}" }
    ]

    save_rows!(rows, prompt_reconstructible: true)

    file = File.read(transcript_path("sid-h"))
    refute_includes file, token, "PATTERNS-matched tokens never reach the durable copy"
    refute_includes file, "supersecret-value-1", "secret-shaped args are masked at save"
    refute_includes file, "sk-#{'x' * 24}", "tool output secrets are masked at save"
    assert_includes file, Rubik::Security::Redactor::MASK_STRING
    assert_includes file, '"retries":3', "non-secret args pass through"
    assert_equal "deploy with #{token} now", rows[1][:content], "memory keeps the wire-faithful copy"
    assert_equal "echo: sk-#{'x' * 24}", rows[3][:content]
  end

  def test_mask_value_matches_recorder_mask_payload_family
    payload = { "api_key" => "keepme-secret", "note" => "secret: hunter2",
                "list" => [{ "auth_token" => "t" * 30 }], "n" => 4 }
    recorder = Rubik::Session::Recorder.new(sessions_dir: File.join(@tmp, "sess"))

    assert_equal recorder.send(:mask_payload, payload), Rubik::Security::Redactor.mask_value(payload),
                 "the subagent channel masks exactly like the root session channel"
  end

  # ---------------------------------------------- Instance ctor bağlantısı

  def build_instance(reconstructible)
    Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-h-1", parent_id: "agent-0", role: "Health Probe",
      type_name: "research", prompt: "probe", context: @context,
      tool_registry: Rubik::Tools::Registry.new, config: Rubik::Config.new(root_dir: @tmp),
      root_dir: @tmp, prompt_reconstructible: reconstructible
    )
  end

  def test_instance_save_transcript_honors_reconstructible_flag
    inst = build_instance(true)
    inst.instance_variable_set(:@history,
                               [{ role: "system", content: "ASSEMBLED-XYZ" }, { role: "user", content: "t" }])

    inst.send(:save_transcript!)

    first = read_rows(inst.transcript_uri).first
    assert_includes first["content"], "prompt_sha256="
    assert_equal Digest::SHA256.hexdigest("ASSEMBLED-XYZ")[0, 16], first["content"].split("=").last
  end

  def test_instance_defaults_to_verbatim_copy
    inst = build_instance(false)
    refute inst.prompt_reconstructible
    inst.instance_variable_set(:@history,
                               [{ role: "system", content: "VERBATIM-KEEP" }, { role: "user", content: "t" }])

    inst.send(:save_transcript!)

    assert_includes File.read(inst.transcript_uri), "VERBATIM-KEEP"
  end

  # -------------------------------------------------- Spawn yolu kararı

  def test_spawn_reconstructibility_follows_the_prompt_origin
    root_context = Rubik::Runtime::Context.new
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: root_context, event_bus: Rubik::EventBus.new, provider: done_provider, root_dir: @tmp
    )
    assert sup.spawn(role: "Scout", prompt: "explore", max_steps: 2).prompt_reconstructible,
           "builtin archetype default is reconstructible"

    refute sup.spawn(role: "Scoped", prompt: "explore", system_prompt: "STRICT-RULES", max_steps: 2).prompt_reconstructible,
           "caller-provided prompt is the only record"

    sup.type_registry.define_custom(name: "auditor", description: "d", system_prompt: "RUNTIME-AUTHORED")
    refute sup.spawn(role: "Aud", prompt: "audit", type_name: "auditor", max_steps: 2).prompt_reconstructible,
           "custom type prompt is the only record"

    assert sup.spawn(role: "Blank", prompt: "x", system_prompt: "   ", max_steps: 2).prompt_reconstructible,
           "a blank caller prompt behaves as absent"
  ensure
    sup&.shutdown_all
    root_context&.dispose unless root_context&.disposed?
  end

  def test_completed_builtin_run_leaves_stub_not_prompt_on_disk
    root_context = Rubik::Runtime::Context.new
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: root_context, event_bus: Rubik::EventBus.new, provider: done_provider, root_dir: @tmp
    )
    inst = sup.spawn(role: "Scout", prompt: "Run briefly", max_steps: 2)
    wait_until { inst.terminal_and_settled? }

    file = File.read(inst.transcript_uri)
    expected = Digest::SHA256.hexdigest(inst.send(:build_effective_system_prompt))[0, 16]
    assert_includes file, "[assembled system prompt omitted] prompt_sha256=#{expected}"
    refute_includes file, "Allocated Step Budget", "the assembled base prompt text stays off disk"
  ensure
    sup&.shutdown_all
    root_context&.dispose unless root_context&.disposed?
  end

  def test_custom_prompt_run_keeps_verbatim_copy_on_disk
    root_context = Rubik::Runtime::Context.new
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: root_context, event_bus: Rubik::EventBus.new, provider: done_provider, root_dir: @tmp
    )
    sup.type_registry.define_custom(name: "auditor", description: "d", system_prompt: "RUNTIME-AUTHORED-RECORD")
    inst = sup.spawn(role: "Aud", prompt: "audit", type_name: "auditor", max_steps: 2)
    wait_until { inst.terminal_and_settled? }

    file = File.read(inst.transcript_uri)
    assert_includes file, "RUNTIME-AUTHORED-RECORD", "custom prompt is the single record — verbatim on disk"
    refute_includes file, "assembled system prompt omitted"
  ensure
    sup&.shutdown_all
    root_context&.dispose unless root_context&.disposed?
  end
end
