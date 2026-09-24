# frozen_string_literal: true

require_relative "../test_helper"

class TestProviderRecovery < Minitest::Test
  # Fake provider at the ONE recovery interface: raises the scripted error
  # on the first call, returns :recovered afterwards.
  class FlakyProvider
    attr_reader :calls

    def initialize(error)
      @error = error
      @calls = 0
    end

    def complete(_history, _opts = {})
      @calls += 1
      raise @error if @error && @calls == 1

      :recovered
    end
  end

  def test_retries_once_on_overflow_and_returns_second_result
    provider = FlakyProvider.new(Rubik::LLM::ClientError.new("maximum context length exceeded"))
    compacted = []

    res = Rubik::Orchestrator::ProviderRecovery.with_recovery(config: nil, compact: ->(reason) { compacted << reason }) do
      provider.complete([], {})
    end

    assert_equal :recovered, res
    assert_equal 2, provider.calls, "exactly one retry"
    assert_equal 1, compacted.size
    assert_includes compacted.first, "maximum context"
  end

  def test_re_raises_non_overflow_errors_without_compacting
    provider = FlakyProvider.new(Rubik::LLM::ClientError.new("rate limit exceeded"))
    compacted = []

    assert_raises(Rubik::LLM::ClientError) do
      Rubik::Orchestrator::ProviderRecovery.with_recovery(config: nil, compact: ->(r) { compacted << r }) do
        provider.complete([], {})
      end
    end
    assert_equal 1, provider.calls
    assert_empty compacted
  end

  def test_second_overflow_propagates_after_single_retry
    calls = []
    always_overflow = Object.new
    always_overflow.define_singleton_method(:complete) do |_h, _o = {}|
      calls << 1
      raise StandardError, "context_length_exceeded: maximum context length is 32768 tokens"
    end
    compacted = []

    err = assert_raises(StandardError) do
      Rubik::Orchestrator::ProviderRecovery.with_recovery(config: nil, compact: ->(r) { compacted << r }) do
        always_overflow.complete([], {})
      end
    end

    assert_equal 2, calls.size
    assert_equal 1, compacted.size, "compaction runs exactly once"
    assert_includes err.message, "context_length_exceeded"
  end

  def test_gate_off_disables_recovery_for_plain_hash_config
    provider = FlakyProvider.new(StandardError.new("maximum context"))

    assert_raises(StandardError) do
      Rubik::Orchestrator::ProviderRecovery.with_recovery(
        config: { "context.auto_recover_on_overflow" => false }, compact: ->(_) {}
      ) { provider.complete([], {}) }
    end
    assert_equal 1, provider.calls
  end

  def test_interrupt_is_not_caught
    compacted = []

    assert_raises(Interrupt) do
      Rubik::Orchestrator::ProviderRecovery.with_recovery(config: nil, compact: ->(_) {}) do
        raise Interrupt, "Ctrl+C"
      end
    end
    assert_empty compacted
  end

  def test_compact_failure_propagates
    provider = FlakyProvider.new(StandardError.new("too many tokens"))

    assert_raises(RuntimeError) do
      Rubik::Orchestrator::ProviderRecovery.with_recovery(config: nil, compact: ->(_) { raise "compactor broke" }) do
        provider.complete([], {})
      end
    end
    assert_equal 1, provider.calls
  end

  def test_overflow_classification
    pr = Rubik::Orchestrator::ProviderRecovery
    assert pr.send(:overflow_error?, StandardError.new("context_length_exceeded"))
    assert pr.send(:overflow_error?, StandardError.new("Your prompt is too long (token limit reached)"))
    assert pr.send(:overflow_error?, StandardError.new("maximum context length is 32768 tokens, but prompt had 35000"))
    assert pr.send(:overflow_error?, StandardError.new("input exceeds the context window"))
    refute pr.send(:overflow_error?, StandardError.new("connection reset by peer"))
    # Transport failures from Go-based proxies must NOT classify as overflow:
    # the bare /context/ alternative was removed specifically for these —
    # misclassification triggers destructive emergency compaction.
    refute pr.send(:overflow_error?, StandardError.new("context deadline exceeded"))
    refute pr.send(:overflow_error?, StandardError.new("context canceled"))
  end

  def test_deadline_error_propagates_without_compaction
    provider = FlakyProvider.new(Rubik::LLM::ClientError.new("context deadline exceeded"))
    compacted = []

    assert_raises(Rubik::LLM::ClientError) do
      Rubik::Orchestrator::ProviderRecovery.with_recovery(config: nil, compact: ->(r) { compacted << r }) do
        provider.complete([], {})
      end
    end
    assert_equal 1, provider.calls, "deadline errors are not overflow: no retry"
    assert_empty compacted
  end

  def test_compaction_config_defensive_variants
    pr = Rubik::Orchestrator::ProviderRecovery
    assert_equal({}, pr.compaction_config(nil))
    assert_equal({}, pr.compaction_config(Object.new))
    assert_equal({}, pr.compaction_config({ "context" => nil }))
    assert_equal({}, pr.compaction_config({ "context" => "not-a-hash" }))
    assert_equal({ "strategy" => "x" }, pr.compaction_config({ "context" => { "strategy" => "x" } }))
  end

  def test_timeout_constants_preserve_per_site_values
    pr = Rubik::Orchestrator::ProviderRecovery
    assert_equal 90, pr::SUBAGENT_REQUEST_TIMEOUT
    assert_equal 120, pr::STREAM_REQUEST_TIMEOUT
    assert_equal 15, pr::DEFAULT_OPEN_TIMEOUT
  end
end
