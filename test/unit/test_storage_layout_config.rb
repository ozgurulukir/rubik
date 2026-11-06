# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/storage/layout"
require_relative "../../lib/rubik/orchestrator/subagent/journal"
require_relative "../../lib/rubik/orchestrator/subagent/result_archive"
require_relative "../../lib/rubik/orchestrator/goal_ledger/ledger"
require_relative "../../lib/rubik/orchestrator/goal_ledger/observation_projection"
require_relative "../../lib/rubik/repl/pruner/service"

class TestStorageLayoutConfig < Minitest::Test
  Layout = Rubik::Storage::Layout

  def test_config_get_with_nil_config_returns_default
    assert_equal "default", Layout.config_get(nil, "some.key", "default")
    assert_nil Layout.config_get(nil, "some.key")
  end

  def test_config_get_with_flat_hash_key
    cfg = { "subagents.result_archive.page_chars" => 2000 }
    assert_equal 2000, Layout.config_get(cfg, "subagents.result_archive.page_chars", 4000)
  end

  def test_config_get_with_nested_hash_key
    cfg = { "subagents" => { "result_archive" => { "page_chars" => 3500 } } }
    assert_equal 3500, Layout.config_get(cfg, "subagents.result_archive.page_chars", 4000)
  end

  def test_config_get_preserves_boolean_false
    cfg_flat = { "feature.enabled" => false }
    assert_equal false, Layout.config_get(cfg_flat, "feature.enabled", true)

    cfg_nested = { "feature" => { "enabled" => false } }
    assert_equal false, Layout.config_get(cfg_nested, "feature.enabled", true)
  end

  def test_config_get_handles_non_hash_in_nested_path
    cfg = { "feature" => false }
    assert_equal "fallback", Layout.config_get(cfg, "feature.nested.setting", "fallback")
  end

  def test_config_get_with_duck_typed_fetch_object
    fetcher = Object.new
    def fetcher.fetch(key, default)
      key == "custom.key" ? "found_it" : default
    end

    assert_equal "found_it", Layout.config_get(fetcher, "custom.key", "miss")
    assert_equal "miss", Layout.config_get(fetcher, "other.key", "miss")
  end

  def test_converged_callers_delegate_to_layout_config_get
    cfg = { "foo.bar" => 42, "nested" => { "baz" => 99 } }

    # Journal
    journal = Rubik::Orchestrator::Subagent::Journal.allocate
    assert_equal 42, journal.send(:config_get, cfg, "foo.bar", 0)
    assert_equal 99, journal.send(:config_get, cfg, "nested.baz", 0)

    # ResultArchive
    archive = Rubik::Orchestrator::Subagent::ResultArchive.new(config: cfg)
    assert_equal 42, archive.send(:config_get, cfg, "foo.bar", 0)
    assert_equal 99, archive.send(:config_get, cfg, "nested.baz", 0)

    # Ledger
    assert_equal 42, Rubik::Orchestrator::GoalLedger::Ledger.send(:config_get, cfg, "foo.bar", 0)
    assert_equal 99, Rubik::Orchestrator::GoalLedger::Ledger.send(:config_get, cfg, "nested.baz", 0)

    # ObservationProjection
    assert_equal 42, Rubik::Orchestrator::GoalLedger::ObservationProjection.send(:config_get, cfg, "foo.bar", 0)
    assert_equal 99, Rubik::Orchestrator::GoalLedger::ObservationProjection.send(:config_get, cfg, "nested.baz", 0)

    # Pruner::Service
    assert_equal 42, Rubik::REPL::Pruner::Service.send(:config_get, cfg, "foo.bar", 0)
    assert_equal 99, Rubik::REPL::Pruner::Service.send(:config_get, cfg, "nested.baz", 0)
  end
end
