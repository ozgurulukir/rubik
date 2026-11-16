# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Hata-sonrası turn resume (2026-11-16): LLM hatasıyla ölen turn REPL
# tarafında @resumable_turn'e saklanır; kullanıcı "devam et" niyetinde bir
# satır yazdığında taze Loop kurulmadan aynı Loop örneği sürdürülür.
class TestTurnErrorResume < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_turn_resume_repl")
    @temp_home = Dir.mktmpdir("rubik_turn_resume_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  # ── Stash + dürüst duyuru ───────────────────────────────────────────
  def test_llm_error_stashes_resumable_loop_and_prints_hint
    loop = fake_loop(step_count: 41, max_steps: 50)

    @shell.handle_llm_client_error!("görev", Rubik::LLM::ClientError.new("Net::ReadTimeout", transient: true), loop)

    assert @shell.resumable_turn?
    assert_includes @output.string, "Turn duraklatıldı (adım 41/50)"
    assert_includes @output.string, "devam et"
  end

  def test_stub_orchestrator_without_resume_contract_is_not_stashed
    bare = Object.new
    bare.define_singleton_method(:history) { [] }

    @shell.handle_llm_client_error!("görev", Rubik::LLM::ClientError.new("boom", transient: true), bare)

    refute @shell.resumable_turn?
    refute_includes @output.string, "Turn duraklatıldı"
  end

  # ── Amaç-eşleşmesi: BİREBİR, substring değil ────────────────────────
  def test_resume_intent_requires_stash_and_exact_match
    refute @shell.resume_intent?("devam et"), "stash yokken niyet yoktur"

    @shell.stash_resumable_turn!(fake_loop)
    assert @shell.resume_intent?("devam et")
    assert @shell.resume_intent?("Devam Et.")
    assert @shell.resume_intent?("devam")
    assert @shell.resume_intent?("continue")
    assert @shell.resume_intent?("sürdür")
    # Sonaki noktalama (+ çoklu-bayt …) soyulur; CodeQL rb/polynomial-redos
    # fix'i pinler (regex yerine düz string soyulması).
    assert @shell.resume_intent?("devam et!!!…")
    assert @shell.resume_intent?("sürdür…?!")
    # Substring/yeni görev metinleri resume SANILMAZ.
    refute @shell.resume_intent?("devam ediyoruz, şimdi başka bir şey yap")
    refute @shell.resume_intent?("devam etmeyi bırak")
    refute @shell.resume_intent?("continue the refactor")
  end

  # ── Dispatch: "devam et" aynı Loop örneğini sürdürür ────────────────
  def test_dispatch_resume_intent_runs_stashed_loop
    loop = fake_loop(step_count: 41, max_steps: 50, result: resumed_result)
    @shell.stash_resumable_turn!(loop)

    @shell.execute_input("devam et")

    calls = loop.resume_calls
    assert_equal 1, calls.size
    assert_equal "llm_error_recovery", calls[0][:reason]
    assert calls[0][:on_step], "resume taze display kanalını sözleşmeye taşır"
    # Dürüst provenance: recorder'a ve konuşma hafızasına "devam et" düşer.
    assert(@shell.conversation_history.any? { |m| m[:role] == "user" && m[:content] == "devam et" })
    assert(@shell.conversation_history.any? { |m| m[:role] == "assistant" && m[:content].to_s.include?("resumed ok") })
    # Tüketilen stash geri dönmez.
    refute @shell.resumable_turn?
  end

  def test_dispatch_other_text_starts_new_task_and_clears_stash
    loop = fake_loop
    @shell.stash_resumable_turn!(loop)
    stub_route_failure!

    @shell.execute_input("başka bir görev")

    assert_empty loop.resume_calls, "resume-niyeti olmayan satır stashed loop'u sürdürmez"
    refute @shell.resumable_turn?, "yeni görev seçimi bayat resume teklifini geçersiz kılar"
    assert_includes @output.string, "Model sağlayıcısı başlatılamadı"
  end

  def test_devam_et_without_stash_runs_as_normal_task
    stub_route_failure!

    @shell.execute_input("devam et")

    assert_includes @output.string, "Model sağlayıcısı başlatılamadı"
    refute @shell.resumable_turn?
  end

  def test_newer_failed_turn_replaces_stash
    first = fake_loop(step_count: 10, max_steps: 50)
    @shell.handle_llm_client_error!("g1", Rubik::LLM::ClientError.new("e1", transient: true), first)
    second = fake_loop(step_count: 20, max_steps: 50)
    @shell.handle_llm_client_error!("g2", Rubik::LLM::ClientError.new("e2", transient: true), second)

    @shell.execute_input("devam et")

    assert_equal 1, second.resume_calls.size
    assert_empty first.resume_calls, "most-recent-wins: yalnız son duraklatılan turn sürdürülür"
  end

  def test_resumed_turn_does_not_duplicate_failed_turn_tool_history
    shared_history = [{ role: "tool", tool_name: "read_file", content: "FILE_CONTENT_A" }]
    loop_obj = fake_loop(step_count: 2, max_steps: 10)
    loop_obj.define_singleton_method(:history) { shared_history }
    loop_obj.define_singleton_method(:resume_turn!) do |reason: nil, on_step: nil|
      _ = reason
      _ = on_step
      shared_history << { role: "tool", tool_name: "grep", content: "GREP_CONTENT_B" }
      { ok: true, output: "done", steps: 3, tokens: { input: 1, output: 1 }, streamed: false, loop_instance: loop_obj }
    end

    @shell.handle_llm_client_error!("task", Rubik::LLM::ClientError.new("timeout", transient: true), loop_obj)
    @shell.execute_input("devam et")

    contents = @shell.conversation_history.select { |m| m[:role] == "tool" }.map { |m| m[:content] }
    assert_equal ["FILE_CONTENT_A", "GREP_CONTENT_B"], contents
  end

  def test_autonomous_turn_llm_error_does_not_clobber_user_resume_stash
    user_loop = fake_loop(step_count: 10, max_steps: 50)
    @shell.handle_llm_client_error!("user task", Rubik::LLM::ClientError.new("e1", transient: true), user_loop)

    auto_loop = fake_loop(step_count: 1, max_steps: 10)
    @shell.instance_variable_set(:@autonomous_turn, true)
    @shell.handle_llm_client_error!("notice", Rubik::LLM::ClientError.new("e2", transient: true), auto_loop)
    @shell.instance_variable_set(:@autonomous_turn, false)

    @shell.execute_input("devam et")
    assert_equal 1, user_loop.resume_calls.size
    assert_empty auto_loop.resume_calls
  end

  private

  # Route fazını deterministik kılar: test ortamı gerçek bir default
  # provider'a (ollama) çözülebilir — turn'in kaderini provider'a bağlı
  # bırakmamak için routing başarısızlığı enjekte edilir.
  def stub_route_failure!
    @shell.define_singleton_method(:resolve_turn_route) { |_text| { provider: nil, spec: "test/unavailable" } }
  end

  # resume_turn! sözleşmesine cevap veren minimal Loop dublörü (duck typing —
  # stash ve dispatch, Loop sınıfını değil sözleşmeyi tanır).
  def fake_loop(step_count: 41, max_steps: 50, result: resumed_result)
    calls = []
    obj = Object.new
    obj.define_singleton_method(:resume_turn!) do |reason: nil, on_step: nil|
      calls << { reason: reason, on_step: on_step }
      result
    end
    obj.define_singleton_method(:resume_calls) { calls }
    obj.define_singleton_method(:step_count) { step_count }
    obj.define_singleton_method(:max_steps) { max_steps }
    obj.define_singleton_method(:history) { [{ role: "tool", tool_name: "t1", content: "x" }] }
    obj.define_singleton_method(:activity) { Rubik::Orchestrator::ActivityLog.new }
    obj.define_singleton_method(:buffer_manager) { nil }
    obj
  end

  def resumed_result
    { ok: true, output: "resumed ok", steps: 42, tokens: { input: 1, output: 1 }, streamed: false }
  end
end
