# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/rubik"

# Hata-sonrası serbest-metin turn resume sözleşmesi (2026-11-16): LLM
# hatasıyla ölen turn aynı Loop örneğinde, aynı @history ve adım bütçesiyle
# sürdürülür. continue_loop/resume! ile aynı execute_steps devam yolu.
class TestOrchestratorTurnResume < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_turn_resume")
    @home_dir = Dir.mktmpdir("rubik_turn_resume_home")
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  def test_resume_turn_preserves_history_prefix_and_step_counters
    provider = counting_error_provider
    loop_instance = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: tool_registry, max_steps: 5)

    # Turn 1: ilk LLM çağrısı Net::ReadTimeout ile ölür (alan raporu kalıbı)
    error = assert_raises(Rubik::LLM::ClientError) { loop_instance.run("Long task") }
    assert_includes error.message, "Network error"

    # Sayaçlar hatadan sonra korunur; history prefix'i nesne-özdeş kalır.
    assert_equal 1, loop_instance.step_count
    prefix_ids = loop_instance.history.map(&:object_id)

    res = loop_instance.resume_turn!

    assert res[:ok]
    assert_equal "resumed ok", res[:output]
    # Devam sözleşmesinin özü: adım sayacı [1/5] konumundan sürer, sıfırlanmaz.
    assert_equal 2, res[:steps]
    assert_equal 2, loop_instance.step_count
    # Aynı diziye ekleme — prefix birebir korunur (run() reset'i DEVRE DIŞI).
    assert_equal prefix_ids, loop_instance.history.first(prefix_ids.size).map(&:object_id)
    marker = loop_instance.history.find { |m| m[:content].to_s.include?("<turn_resumed") }
    refute_nil marker
    assert_includes marker[:content], 'step="1"'
    # Provider 2 kez çağrıldı: hatalı istek + resume.
    assert_equal 2, provider.call_count
  end

  def test_resume_turn_swaps_on_step_to_fresh_display_channel
    provider = counting_error_provider
    events = []
    loop_instance = Rubik::Orchestrator::Loop.new(
      provider: provider, tool_registry: tool_registry, max_steps: 5,
      on_step: ->(info) { events << info }
    )
    assert_raises(Rubik::LLM::ClientError) { loop_instance.run("Long task") }

    fresh_events = []
    loop_instance.resume_turn!(on_step: ->(info) { fresh_events << info })

    # Taze kanal resume koşusunun olaylarını taşır; ölü turn'in handler'ı
    # devre dışıdır (resume sırasında eski kanala :thinking sızmaz).
    assert(fresh_events.any? { |i| i[:type] == :thinking && i[:step] == 2 })
    refute(events.any? { |i| i.is_a?(Hash) && i[:step] == 2 && i[:type] == :thinking })
  end

  def test_resume_turn_escapes_and_caps_reason_and_preserves_model_override
    seen_opts = []
    provider = Class.new do
      define_method(:complete) do |_history, opts = {}|
        seen_opts << opts
        raise Rubik::LLM::ClientError.new("transient", transient: true) if seen_opts.size == 1

        Struct.new(:text, :tool_calls?, :tool_calls, :usage).new(
          '{"tool": "finish", "args": { "message": "ok" }}',
          true,
          [{ "tool" => "finish", args: { message: "ok" } }],
          nil
        )
      end
    end.new

    loop_inst = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: tool_registry, max_steps: 5)
    assert_raises(Rubik::LLM::ClientError) { loop_inst.run("task", model: "override-model") }

    res = loop_inst.resume_turn!(reason: 'foo" injected="yes')
    assert res[:ok]
    assert_equal "override-model", seen_opts[0][:model]
    assert_equal "override-model", seen_opts[1][:model]

    marker = loop_inst.history.find { |m| m[:content].to_s.include?("<turn_resumed") }[:content]
    assert_includes marker, 'reason="foo&quot; injected=&quot;yes"'
    refute_includes marker, 'injected="yes"'
  end

  private

  # İlk çağrıda transient ağ hatası, sonrakinde finish — alan raporundaki
  # [41/50] Net::ReadTimeout → "devam et" senaryosunun küçültülmüş kalıbı.
  def counting_error_provider
    Class.new do
      def complete(_history, _opts = {})
        @calls ||= 0
        @calls += 1
        raise Rubik::LLM::ClientError.new("Network error during stream from example: Net::ReadTimeout", transient: true) if @calls == 1

        Struct.new(:text, :tool_calls?, :tool_calls, :usage).new(
          '{"tool": "finish", "args": { "message": "resumed ok" }}',
          true,
          [{ "tool" => "finish", args: { message: "resumed ok" } }],
          nil
        )
      end

      def call_count = @calls
    end.new
  end

  def tool_registry
    reg = Rubik::Tools::Registry.new
    tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize = super(name: "list_files", description: "List files")
      def execute(_) = "ok"
    end.new
    reg.register(tool)
    reg
  end
end
