# frozen_string_literal: true

require_relative "../test_helper"

# Tarama kartı 5 (2026-11-01): araç-çıktı normalizasyon sözleşmesi iki
# düzlemde yaşar — root StepExecutor#normalize_raw_output ve subagent
# ToolDispatch#normalize_tool_result. Eski anti-drift mekanizması prose
# yorumdu ("Same classification ... cannot drift"); bu süit sözleşmeyi
# pinler: aynı taşıyıcı iki düzlemde aynı sınıflamayı alır, truncation
# knob'u her iki düzlemde onurlanır ve her iddia Truncator ORACLE'ına
# karşı mutlak doğrulanır (review F5 — düzlemler birlikte regresyona
# gitse bile süit kör kalmaz). Hata taşıyıcıları (Error: öneki, failed?,
# error'suz :error Result) sınıflandırma paritesinin canlı kanıtıdır.
class TestToolOutputNormalizationParity < Minitest::Test
  BIG = "line\n" * 10_000
  ERR_LINES = "Error: disk exploded\n" * 500

  def root_normalize(raw, config: {})
    deps = Struct.new(:shell).new(Struct.new(:config).new(config))
    executor = Rubik::Orchestrator::StepExecutor.allocate
    executor.instance_variable_set(:@deps, deps)
    executor.send(:normalize_raw_output, raw, "probe", "call-1", 1.0)
  end

  def subagent_normalize(raw, config: {})
    host = Object.new
    host.extend(Rubik::Orchestrator::Subagent::ToolDispatch)
    host.instance_variable_set(:@config, config)
    tool = Object.new
    tool.define_singleton_method(:execute) { |_args| raw }
    host.dispatch_subagent_tool(tool, "probe", {})
  end

  def carriers
    big = BIG
    err = ERR_LINES
    {
      result: [big, -> { Rubik::Tools::Result.new(tool_name: "gen", status: :ok, output: big, exit_code: 0, duration_ms: 1) }],
      error_result: [big, -> { Rubik::Tools::Result.new(tool_name: "gen", status: :error, output: big, error: nil, exit_code: 1, duration_ms: 1) }],
      duck: [big, -> { Struct.new(:status, :output).new(:ok, big) }],
      string: [big, -> { big.dup }],
      error_string: [err, -> { err.dup }],
      failed_object: [big, lambda {
        obj = Object.new
        obj.define_singleton_method(:to_s) { big }
        obj.define_singleton_method(:failed?) { true }
        obj
      }]
    }
  end

  def test_same_carrier_classifies_and_truncates_identically_in_both_planes
    carriers.each do |kind, (body, factory)|
      raw = factory.call
      root = root_normalize(raw, config: {})
      sub = subagent_normalize(raw, config: {})
      oracle = Rubik::Tools::Truncator.truncate(body)

      assert_equal oracle[:truncated], root.truncated, "#{kind}: root must agree with the Truncator oracle"
      assert_equal oracle[:text], root.output, "#{kind}: root must agree with the Truncator oracle"
      assert_equal root.status, sub.status, "#{kind}: status classification must match"
      assert_equal root.error, sub.error, "#{kind}: error backfill must match"
      assert_equal root.output, sub.output, "#{kind}: truncation must match under the default knobs"
      assert_equal root.truncated, sub.truncated, "#{kind}: truncation flag must match"
    end

    assert_equal :error, root_normalize("Error: boom", config: {}).status, "the Error: prefix must classify as :error"
    assert_equal :error, subagent_normalize("Error: boom", config: {}).status
    assert_equal :error, root_normalize(carriers[:error_result][1].call, config: {}).status
    assert_equal :error, subagent_normalize(carriers[:error_result][1].call, config: {}).status
    assert_equal :error, root_normalize(carriers[:failed_object][1].call, config: {}).status
    assert_equal :error, subagent_normalize(carriers[:failed_object][1].call, config: {}).status
  end

  def test_truncation_strategy_knob_is_honored_in_both_planes
    ["tail_only", "head_only"].each do |strategy|
      cfg = { "tools.truncation_strategy" => strategy }
      root = root_normalize(BIG, config: cfg)
      sub = subagent_normalize(BIG, config: cfg)
      oracle = Rubik::Tools::Truncator.truncate(BIG, strategy: strategy)

      assert_equal oracle[:text], root.output, "strategy=#{strategy}: root must agree with the Truncator oracle"
      assert_equal oracle[:text], sub.output, "strategy=#{strategy}: subagent must agree with the Truncator oracle"
      assert_equal root.truncated, sub.truncated
      assert root.truncated
      assert_includes root.output, "Truncated:"
    end
  end

  def test_subagent_plane_without_config_falls_back_to_truncator_defaults
    sub = subagent_normalize(BIG, config: nil)

    assert sub.truncated
    assert_equal Rubik::Tools::Truncator.truncate(BIG).fetch(:text), sub.output,
                 "a config-less subagent plane must truncate exactly like the Truncator defaults"
  end
end
