# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/llm/client"
require_relative "../../lib/rubik/orchestrator/goal_registry"
require_relative "../../lib/rubik/orchestrator/goal_ledger"
require_relative "../../lib/rubik/runtime/context"

# !goal resume omurgası (issue #106): (1) ClientError#transient? sınıflandır
# ması — bayrak raise noktalarında karar verilir, mesaj okunmaz; (2) Goal
# State askı/resume yaşam döngüsü; (3) GoalRegistry zero-restart; (4) Σ
# damgası + Ledger.load rehidrasyonu + zincir sürekliliği; (5) degrade
# sözleşmesi.
class TestGoalResume < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  FakeResponse = Struct.new(:code, :body, :headers) do
    def key?(name) = headers.key?(name)

    def [](name) = headers[name]

    def read_body
      yield body if block_given?
      body
    end
  end

  # Dönen yanıt sırasını (veya raise edilecek hata sınıflarını) oynatır;
  # streaming blok formunu da destekler.
  class FakeHttp
    attr_accessor :read_timeout, :open_timeout

    def initialize(responses)
      @responses = responses.dup
    end

    def request(_req)
      resp = @responses.size > 1 ? @responses.shift : @responses.first
      raise resp if resp.is_a?(Class) || resp.is_a?(StandardError)

      yield resp if block_given?
      resp
    end
  end

  GOAL_TEST_ENDPOINT = "https://api.example.com/v1/chat"

  def exercise_batch(http, **)
    # Literal endpoint + factory seam — test_llm_retry.rb mold'u.
    Rubik::LLM::HTTPClient.post_json(
      GOAL_TEST_ENDPOINT, payload: { model: "x" },
                          http_factory: ->(_uri) { http }, **
    )
  end

  # ---- ClientError#transient? — batch raise noktaları ----

  def test_default_client_error_is_permanent
    refute Rubik::LLM::ClientError.new("content policy").transient?
    refute Rubik::LLM::ClientError.new("content policy", transient: false).transient?
    assert Rubik::LLM::ClientError.new("x", transient: true).transient?
  end

  def test_exhausted_5xx_is_transient
    err = assert_raises(Rubik::LLM::ClientError) do
      exercise_batch(FakeHttp.new([FakeResponse.new(500, "provider on fire")]), max_retries: 0)
    end
    assert err.transient?, "exhausted 5xx must classify transient (provider outage)"
  end

  def test_4xx_is_permanent
    err = assert_raises(Rubik::LLM::ClientError) do
      exercise_batch(FakeHttp.new([FakeResponse.new(400, "-20058 moderation")]))
    end
    refute err.transient?, "4xx content/auth/moderation must stay terminal"
  end

  def test_retryable_transport_exhaustion_is_transient
    err = assert_raises(Rubik::LLM::ClientError) do
      exercise_batch(FakeHttp.new([Errno::ECONNREFUSED]), max_retries: 0)
    end
    assert err.transient?, "DNS/connect exhaustion is the field incident's exact class"
  end

  def test_read_timeout_is_permanent_by_design
    err = assert_raises(Rubik::LLM::ClientError) do
      exercise_batch(FakeHttp.new([Net::ReadTimeout]))
    end
    refute err.transient?, "the server is still generating — resume would duplicate the request"
  end

  def test_json_parse_failure_is_permanent
    err = assert_raises(Rubik::LLM::ClientError) do
      exercise_batch(FakeHttp.new([FakeResponse.new(200, "not json")]))
    end
    refute err.transient?
  end

  def test_rate_limit_error_is_transient
    err = assert_raises(Rubik::LLM::RateLimitError) do
      exercise_batch(FakeHttp.new([FakeResponse.new(429, "slow down")]), max_429_retries: 0)
    end
    assert err.transient?, "429 throttling must suspend, not fail"
  end

  # ---- ClientError#transient? — streaming raise noktaları ----

  def test_stream_transport_failure_is_transient
    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "https://api.example.com/v1/stream", payload: { model: "x" },
                                             http_factory: ->(_uri) { FakeHttp.new([Errno::ECONNRESET]) }
      ) { |event| event }
    end
    assert err.transient?, "stream connect-phase failure before any byte must classify transient"
  end

  def test_stream_5xx_is_transient
    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "https://api.example.com/v1/stream", payload: { model: "x" },
                                             http_factory: ->(_uri) { FakeHttp.new([FakeResponse.new(502, "bad gateway")]) }
      ) { |event| event }
    end
    assert err.transient?
  end

  def test_stream_4xx_is_permanent
    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "https://api.example.com/v1/stream", payload: { model: "x" },
                                             http_factory: ->(_uri) { FakeHttp.new([FakeResponse.new(403, "forbidden")]) }
      ) { |event| event }
    end
    refute err.transient?
  end

  def test_stream_429_is_transient
    err = assert_raises(Rubik::LLM::RateLimitError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "https://api.example.com/v1/stream", payload: { model: "x" },
                                             http_factory: ->(_uri) { FakeHttp.new([FakeResponse.new(429, "throttled")]) }
      ) { |event| event }
    end
    assert err.transient?
  end

  # ---- GoalState suspend/resume ----

  def goal_state(bus: nil)
    Rubik::Orchestrator::GoalState.new(event_bus: bus)
  end

  def test_suspend_preserves_counters_and_is_not_terminal
    gs = goal_state
    gs.start!("Fix tests", 10)
    gs.update_steps(4, 10)
    gs.record_tokens!({ input: 5, output: 6 })

    gs.suspend!("Network error calling api.example.com (gave up after 2 retries)")

    assert gs.suspended?
    assert_equal 4, gs.step_count, "suspend must preserve the step counter"
    assert_equal 6, gs.tokens[:output]
    assert_nil gs.snapshot[:finished_at], "suspend is not terminal — no finished_at"
    assert_includes gs.last_error, "Network error"
    assert_includes gs.to_xml, 'status="suspended"'
  end

  def test_suspend_posts_goal_suspended_event
    events = []
    bus = Object.new
    bus.define_singleton_method(:post) { |*args| events << args }
    gs = goal_state(bus: bus)
    gs.start!("g", 5)
    gs.suspend!("DNS failure")

    assert_equal 1, events.size
    event_name, payload, kwargs = events.first
    assert_equal Rubik::Orchestrator::GoalState::SUSPEND_EVENT, event_name
    assert_equal "suspended", payload[:status]
    assert_equal "DNS failure", payload[:last_error]
    assert_equal :orchestrator, kwargs[:subsystem]
  end

  def test_suspend_is_noop_outside_running
    gs = goal_state
    gs.start!("g", 5)
    gs.suspend!("first")
    gs.suspend!("double suspend must be a silent no-op")
    assert_equal "first", gs.last_error

    finished = goal_state
    finished.start!("g", 5)
    finished.complete!("done")
    finished.suspend!("post-terminal suspend must be a no-op")
    assert_equal :completed, finished.status
  end

  def test_resume_restores_running_and_terminal_paths_work_again
    gs = goal_state
    gs.start!("g", 5)
    gs.update_steps(3, 5)
    gs.suspend!("transient")
    gs.resume!

    assert gs.running?
    assert_nil gs.last_error
    assert_equal 3, gs.step_count, "resume must keep the counters"
    gs.complete!("all green")
    assert_equal :completed, gs.status, "resume ≙ Activating: terminal paths guard on :running"
  end

  def test_restore_counters_takes_absolute_values_in_both_key_dialects
    gs = goal_state
    gs.start!("g", 100)
    gs.update_steps(50, 100)
    gs.restore_counters!(steps: 17, max_steps: 40, extensions: 2, tokens: { input: 11, output: 22 })
    assert_equal({ status: :running, steps: 17, max_steps: 40, extensions: 2, input: 11, output: 22 },
                 gs.snapshot.slice(:status).merge(steps: gs.step_count, max_steps: gs.max_steps,
                                                  extensions: gs.extensions, input: gs.tokens[:input],
                                                  output: gs.tokens[:output]))

    # Σ damgası JSON roundtrip'i dizge anahtarlı gelir — aynı sonuç.
    gs2 = goal_state
    gs2.start!("g", 100)
    gs2.restore_counters!(steps: "9", max_steps: "40", extensions: "1", tokens: { "input" => 3, "output" => 4 })
    assert_equal 9, gs2.step_count
    assert_equal 40, gs2.max_steps
    assert_equal({ input: 3, output: 4 }, gs2.tokens)
  end

  # ---- GoalRegistry zero-restart ----

  def entry(id, attempt)
    Rubik::Orchestrator::GoalRegistry::Entry.new(goal_id: id, goal_text: "g", loop: nil,
                                                 goal_state: nil, ledger: nil, reason: "r",
                                                 suspended_at: Time.now, attempt: attempt)
  end

  def test_registry_repeated_suspend_cycles_keep_a_single_entry
    registry = Rubik::Orchestrator::GoalRegistry.new
    1000.times { |i| registry.register(entry("goal-1", i + 1)) }
    assert_equal 1, registry.size, "1000 suspend/resume cycles must not stack entries"
    assert_equal 1000, registry.latest.attempt
  end

  def test_registry_latest_fetch_delete
    registry = Rubik::Orchestrator::GoalRegistry.new
    registry.register(entry("a", 1))
    registry.register(entry("b", 1))
    assert_equal "b", registry.latest.goal_id, "resume revives the most recent suspension"
    registry.delete("b")
    assert_equal "a", registry.latest.goal_id
    assert_nil registry.fetch("b")
  end

  def test_registry_latest_tracks_the_most_recent_suspension_not_insertion
    registry = Rubik::Orchestrator::GoalRegistry.new
    registry.register(entry("a", 1))
    registry.register(entry("b", 1))
    assert_equal "b", registry.latest.goal_id

    # The corner: the OLDER suspension re-suspends (resume → suspend again).
    # Recency — not first-insertion order — must decide what !goal resume
    # revives (COMMANDS.md: "the most recent suspension").
    registry.register(entry("a", 2))
    assert_equal 2, registry.size, "re-suspension updates its own entry"
    assert_equal "a", registry.latest.goal_id, "latest must follow the most recent suspension"
    assert_equal 2, registry.latest.attempt
  end

  # ---- Σ damgası: suspend!/unsuspend!/load ----

  def setup
    @root = Dir.mktmpdir("goal-resume-test")
    @store = Rubik::Storage::Store.new(root: @root, project: "resume-test")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def led
    GL::Ledger.create!(goal_text: "Fix the payment module", store: @store)
  end

  def stamp_meta(attempt: 1)
    { goal_id: "goal-1", steps: 12, max_steps: 100, extensions: 1,
      tokens: { input: 5, output: 6 }, reason: "DNS failure", suspended_at: Time.now.utc.iso8601,
      attempt: attempt }
  end

  def test_suspend_stamps_the_same_row_and_keeps_the_chain_flat
    ledger = led
    ledger.update(JSON.generate({ "rev" => 0, "ops" => [{ "op" => "add", "path" => "/tasks/-",
                                                          "value" => { "id" => "t1", "title" => "Design retry", "status" => "todo" } }] }))
    id_before = ledger.snapshot[:storage_id]
    rows_before = @store.list(type: "goal").size

    ledger.suspend!(stamp_meta)

    row = @store.get(type: "goal", id: id_before)
    assert_equal "suspended", row["status"], "storage status flips to suspended"
    assert_equal id_before, row["id"], "stamp is row-addressed — id preserved (version++)"
    assert_equal rows_before, @store.list(type: "goal").size, "stamp must NOT add rows (zero-restart)"
    meta = JSON.parse(row.dig("links", "suspended"))
    assert_equal "goal-1", meta["goal_id"]
    assert_equal 12, meta["steps"]
    assert_equal 1, meta["attempt"]
    refute ledger.snapshot[:finalized], "suspend is not terminal"
    assert ledger.snapshot[:suspended]
  end

  def test_repeated_suspend_overwrites_the_stamp_without_growing_rows
    ledger = led
    ledger.suspend!(stamp_meta(attempt: 1))
    ledger.suspend!(stamp_meta(attempt: 2))
    assert_equal 1, @store.list(type: "goal").size, "repeated suspends rotate the same row"
    row = @store.get(type: "goal", id: ledger.snapshot[:storage_id])
    assert_equal 2, JSON.parse(row.dig("links", "suspended"))["attempt"]
  end

  def test_unsuspend_clears_the_stamp_and_memory_meta
    ledger = led
    ledger.suspend!(stamp_meta)
    ledger.unsuspend!

    row = @store.get(type: "goal", id: ledger.snapshot[:storage_id])
    assert_equal "active", row["status"], "a resumed goal must not list as suspended"
    assert_nil ledger.suspend_meta
    refute ledger.snapshot[:suspended]
  end

  def test_finalize_overwrites_the_suspend_stamp
    ledger = led
    ledger.suspend!(stamp_meta)
    ledger.finalize!(:failed)
    row = @store.get(type: "goal", id: ledger.snapshot[:storage_id])
    assert_equal "failed", row["status"], "terminal paths overwrite the stamp (no suspended row survives)"
    assert_nil row.dig("links", "suspended"), "terminal links drop the suspend meta"
  end

  def test_load_rehydrates_and_first_acceptance_writes_a_new_linked_row
    ledger = led
    ledger.update(JSON.generate({ "rev" => 0, "ops" => [{ "op" => "add", "path" => "/findings/-",
                                                          "value" => { "id" => "f1", "text" => "root cause: DNS", "source_step" => 3 } }] }))
    suspended_id = ledger.snapshot[:storage_id]
    rev_before = ledger.rev
    ledger.suspend!(stamp_meta)

    rehydrated = GL::Ledger.load(store: @store, storage_id: suspended_id)
    refute_nil rehydrated, "load must rehydrate a suspended stamp"
    assert_equal rev_before, rehydrated.rev, "Σ rev is restored from the body"
    assert_equal "root cause: DNS", rehydrated.snapshot_doc["findings"].first["text"]
    assert_equal "goal-1", rehydrated.suspend_meta["goal_id"]
    assert_equal suspended_id, rehydrated.snapshot[:storage_id]

    # Zincir sürekliliği: ilk kabul YENİ satır, ledger_prev → askı satırı,
    # rev monoton. The acceptance chain continues under the existing contract.
    replan_patch = JSON.generate({
                                   "rev" => rev_before,
                                   "ops" => [{ "op" => "add", "path" => "/tasks/-",
                                               "value" => { "id" => "t2", "title" => "Replan", "status" => "todo" } }]
                                 })
    res = rehydrated.update(replan_patch)
    assert_equal :applied, res.status
    new_id = rehydrated.snapshot[:storage_id]
    refute_equal suspended_id, new_id, "first post-resume acceptance must write a NEW row"
    new_row = @store.get(type: "goal", id: new_id)
    assert_equal suspended_id, new_row.dig("links", "ledger_prev")
    assert_operator rehydrated.rev, :>, rev_before, "rev stays monotonic across resume"
  end

  def test_load_honestly_refuses_non_suspended_or_corrupt_rows
    ledger = led
    id = ledger.snapshot[:storage_id]
    assert_nil GL::Ledger.load(store: @store, storage_id: id), "an active row is not a suspend stamp"
    assert_nil GL::Ledger.load(store: @store, storage_id: "goal.999.deadbeefdeadbeef")
    assert_nil GL::Ledger.load(store: nil, storage_id: id), "no store → honest refusal"
    assert_nil GL::Ledger.load(store: @store, storage_id: nil)

    ledger.suspend!(stamp_meta)
    # Corrupt body: load refuses instead of crashing.
    @store.put(type: "goal", id: ledger.snapshot[:storage_id], title: "t", body: "{not json",
               tags: ["goal-ledger"], links: {}, status: "suspended")
    assert_nil GL::Ledger.load(store: @store, storage_id: ledger.snapshot[:storage_id])

    # Schema-corrupt body: parseable JSON with rev+objective but missing the
    # Σ collections must be refused AT LOAD — not after unsuspend! has
    # already consumed the stamp (the resume would otherwise die later in
    # render_xml as NoMethodError, with the clean-refusal path closed).
    @store.put(type: "goal", id: ledger.snapshot[:storage_id], title: "t",
               body: JSON.generate({ "rev" => 1, "objective" => "half-baked" }),
               tags: ["goal-ledger"], links: {}, status: "suspended")
    assert_nil GL::Ledger.load(store: @store, storage_id: ledger.snapshot[:storage_id]),
               "a body without the five Σ collections is not a resumable stamp"
  end

  def test_suspend_degrades_without_store_but_keeps_in_process_resume_alive
    ledger = nil
    warns = capture_warnings do
      ledger = GL::Ledger.create!(goal_text: "no store", store: nil)
      ledger.suspend!(stamp_meta)
      ledger.unsuspend!
    end
    storage_warns = warns.count { |w| w.include?("storage unavailable") }
    assert_equal 1, storage_warns, "no-store degradation warns ONCE (memoized) — create, suspend, unsuspend included"
    assert_equal "goal-1", ledger.suspend_meta["goal_id"], "meta is still recorded in memory — in-process resume works"
  end

  def capture_warnings(&)
    warns = []
    Rubik::Log.stub(:warn, ->(*args) { warns << args.join(" ") }, &)
    warns
  end

  # ---- Ω disiplini: registry provide-swap tek inverse tutar ----

  def test_goal_registry_provide_swap_keeps_the_accumulator_at_its_baseline
    ctx = Rubik::Runtime::Context.new
    registry = Rubik::Orchestrator::GoalRegistry.new
    ctx.provide(Rubik::Coeffects::GOAL_REGISTRY, registry)
    depth_after_first = cleanup_depth(ctx)

    1000.times do |i|
      registry.register(entry("goal-1", i + 1))
      ctx.provide(Rubik::Coeffects::GOAL_REGISTRY, registry) # resume handler's re-provide
    end

    assert_equal depth_after_first, cleanup_depth(ctx), "provide-swap must never stack inverses (§6 zero-restart)"
    assert_same registry, Rubik::Coeffects.get(ctx, Rubik::Coeffects::GOAL_REGISTRY)
  ensure
    ctx&.dispose
  end

  def cleanup_depth(ctx)
    # Production Runtime::Context: per-key inverse registries + the LIFO
    # disposable stack. Provide-swap may touch none of them repeatedly.
    ctx.instance_variable_get(:@disposables).size +
      ctx.instance_variable_get(:@service_inverses).size
  end
end
