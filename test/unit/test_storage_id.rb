# frozen_string_literal: true

require_relative "../test_helper"

# Plan 110: process-unique transcript storage ids. The display id keeps its
# model-facing meaning (subagent-1 everywhere); only storage paths carry the
# pid/epoch/rand4 suffix, so two sessions in one workspace can never collide.
#
# Uniqueness is pinned only where the scheme GUARANTEES it: cross-process
# (pid factor) and cross-second (epoch factor). Same-second mints carry a
# 1/9000 birthday residual per pair (D1) — asserting 100 same-second mints
# unique would fail ~42% of runs by the plan's own math — so no same-second
# uniqueness claim is tested; production never mints two same-display-id
# instances in one process, and the test DI seam gives each supervisor its
# own root even if it did.
class TestStorageId < Minitest::Test
  def test_mint_keeps_display_id_prefix_and_carries_the_three_factors
    id = Rubik::Orchestrator::Subagent::StorageId.mint("subagent-1")
    assert_match(/\Asubagent-1-\d+-\d+-\d+\z/, id, "storage id = display id + pid + epoch + rand4")
    assert_includes id, "-#{Process.pid}-", "the pid factor must be embedded verbatim"
  end

  def test_mint_is_charset_safe_for_paths_and_urls
    assert_match(/\A[a-zA-Z0-9_-]+\z/, Rubik::Orchestrator::Subagent::StorageId.mint("subagent-1"))
  end

  def test_mints_in_different_seconds_never_collide
    before = Rubik::Orchestrator::Subagent::StorageId.mint("subagent-1")
    sleep 1.05
    after = Rubik::Orchestrator::Subagent::StorageId.mint("subagent-1")

    refute_equal before, after, "cross-second mints differ by epoch — guaranteed unique"
  end
end
