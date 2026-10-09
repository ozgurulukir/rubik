# frozen_string_literal: true

require_relative "../test_helper"

class TestFuzzyMatcher < Minitest::Test
  def test_best_matches_with_typos
    candidates = ["read_file", "write_file", "list_files", "grep_search", "search_symbols", "run_command", "finish"]

    matches = Rubik::Tools::FuzzyMatcher.best_matches("red_file", candidates)
    assert_includes matches, "read_file"

    matches_grep = Rubik::Tools::FuzzyMatcher.best_matches("grp_search", candidates)
    assert_includes matches_grep, "grep_search"

    matches_cmd = Rubik::Tools::FuzzyMatcher.best_matches("run_comand", candidates)
    assert_includes matches_cmd, "run_command"
  end

  def test_similarity_ratio
    assert_in_delta 1.0, Rubik::Tools::FuzzyMatcher.similarity_ratio("hello", "hello"), 0.001
    assert_equal 0.0, Rubik::Tools::FuzzyMatcher.similarity_ratio("", "hello")
    assert_equal 0.0, Rubik::Tools::FuzzyMatcher.similarity_ratio("hello", "")

    sim = Rubik::Tools::FuzzyMatcher.similarity_ratio("replace_file", "replace_file_content")
    assert sim > 0.5
    assert sim < 1.0
  end

  def test_length_bound_prune_returns_zero_for_unreachable_candidates
    # len_diff 7 / max 10 -> upper bound 0.3 < 0.35: pruned to 0.0 without computing distance
    assert_equal 0.0, Rubik::Tools::FuzzyMatcher.similarity_ratio("abc", "x" * 10, min_threshold: 0.35)
  end

  def test_length_bound_prune_keeps_boundary_candidates_computable
    # len_diff 4 / max 8 -> upper bound exactly 0.5 >= 0.35: not pruned, true distance used
    sim = Rubik::Tools::FuzzyMatcher.similarity_ratio("abcd", "abcdefgh", min_threshold: 0.35)
    assert_in_delta 0.5, sim, 0.001
  end

  def test_pruning_preserves_best_matches_results
    candidates = ["read_file", "write_file", "list_files", "grep_search", "search_symbols", "run_command", "finish"]

    assert_includes Rubik::Tools::FuzzyMatcher.best_matches("red_file", candidates), "read_file"
    assert_empty Rubik::Tools::FuzzyMatcher.best_matches("zzzzzzzzzzzzzzzz", candidates)
  end

  def test_find_closest_subsequence_with_lcs
    file_content = <<~RUBY
      def calculate_total(items)
        items.sum(&:price)
      end

      def max_retry_attempts
        3
      end

      def process_order(order)
        order.process!
      end
    RUBY

    target = <<~RUBY
      def max_retries
        3
      end
    RUBY

    closest = Rubik::Tools::FuzzyMatcher.find_closest_subsequence(target, file_content)
    refute_nil closest
    assert_includes closest[:snippet], "max_retry_attempts"
    assert_includes closest[:snippet], "3"
    assert closest[:similarity] > 50
    assert_equal 5..7, closest[:range]
  end

  def test_find_closest_subsequence_empty_cases
    assert_nil Rubik::Tools::FuzzyMatcher.find_closest_subsequence("", "some content")
    assert_nil Rubik::Tools::FuzzyMatcher.find_closest_subsequence("some target", "")
  end
end
