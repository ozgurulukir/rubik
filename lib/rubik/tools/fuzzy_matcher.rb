# frozen_string_literal: true

require "did_you_mean"
begin
  require "diff/lcs"
rescue LoadError
  # fallback if not yet installed in some minimal environments
end

module Rubik
  module Tools
    # Provides fast, stdlib-powered spelling suggestions and closest-subsequence
    # matching for Elm-style actionable diagnostics (Plan 56 D-1).
    class FuzzyMatcher
      # Returns the top candidates closest to `query` using DidYouMean::SpellChecker
      # and Levenshtein similarity ranking.
      #
      # @param query [String] Search query or misspelled token
      # @param candidates [Array<String>] Dictionary of valid identifiers
      # @param limit [Integer] Maximum number of suggestions to return
      # @return [Array<String>] Sorted list of closest matches
      # Single source of truth for the candidate-score cutoff in best_matches
      # and the length-bound prune inside similarity_ratio - keep them tied.
      MATCH_THRESHOLD = 0.35

      def self.best_matches(query, candidates, limit: 3)
        return [] if query.to_s.strip.empty? || candidates.nil? || candidates.empty?

        str_query = query.to_s.downcase.strip
        str_candidates = candidates.map { |c| c.to_s.downcase.strip }.reject(&:empty?).uniq

        # Direct spell check via stdlib if available
        dym_matches = []
        if defined?(DidYouMean::SpellChecker)
          checker = DidYouMean::SpellChecker.new(dictionary: str_candidates)
          dym_matches = checker.correct(str_query)
        end

        # Substring inclusions get prioritized
        substring_matches = str_candidates.select { |c| c.include?(str_query) || str_query.include?(c) }

        # Rank all candidates by Levenshtein similarity ratio
        # PERF: pass min_threshold to prune candidates whose length difference
        # prevents them from ever reaching MATCH_THRESHOLD
        scored_pairs = str_candidates.map do |cand|
          score = similarity_ratio(str_query, cand, min_threshold: MATCH_THRESHOLD)
          [cand, score]
        end
        scored = scored_pairs.select { |_c, score| score >= MATCH_THRESHOLD }
                             .sort_by { |_c, score| -score }
                             .map(&:first)

        (dym_matches + substring_matches + scored).uniq.first(limit)
      end

      # Computes normalized string similarity ratio in [0.0, 1.0].
      #
      # @param str1 [String] First string
      # @param str2 [String] Second string
      # @param min_threshold [Float, nil] Optional minimum acceptable score for early upper-bound pruning
      # @return [Float] Similarity score (1.0 = exact match)
      def self.similarity_ratio(str1, str2, min_threshold: nil)
        s1 = str1.to_s.downcase
        s2 = str2.to_s.downcase
        return 1.0 if s1 == s2
        return 0.0 if s1.empty? || s2.empty?

        l1 = s1.length
        l2 = s2.length
        max_len = l1 > l2 ? l1.to_f : l2.to_f

        if min_threshold
          len_diff = (l1 - l2).abs
          # PERF: Upper-bound check on string length difference; if max achievable ratio < min_threshold, prune edit distance calculation
          return 0.0 if (1.0 - (len_diff / max_len)) < min_threshold
        end

        dist = levenshtein_distance(s1, s2)
        [1.0 - (dist / max_len), 0.0].max
      end

      # Computes Levenshtein edit distance between two strings using standard dynamic programming.
      def self.levenshtein_distance(str1, str2)
        return DidYouMean::Levenshtein.distance(str1.to_s, str2.to_s) if defined?(DidYouMean::Levenshtein) && DidYouMean::Levenshtein.respond_to?(:distance)

        s1 = str1.to_s.chars
        s2 = str2.to_s.chars
        return s2.length if s1.empty?
        return s1.length if s2.empty?

        d = Array.new(s1.length + 1) { |i| i }

        s2.each_with_index do |char2, j|
          new_d = [j + 1]
          s1.each_with_index do |char1, i|
            cost = char1 == char2 ? 0 : 1
            new_d << [
              d[i + 1] + 1,       # deletion
              new_d[i] + 1,       # insertion
              d[i] + cost         # substitution
            ].min
          end
          d = new_d
        end

        d.last
      end

      # Finds the closest matching line window in `file_content` for `target_content`
      # using Longest Common Subsequence (LCS) analysis (Plan 56 D-1/D-3).
      #
      # @param target_content [String] The snippet being searched
      # @param file_content [String] Full file content
      # @return [Hash, nil] { snippet:, range:, similarity: } or nil if no good match
      def self.find_closest_subsequence(target_content, file_content)
        t_raw = target_content.to_s.gsub("\r\n", "\n")
        f_raw = file_content.to_s.gsub("\r\n", "\n")
        t_lines = t_raw.lines.map(&:rstrip)
        f_lines = f_raw.lines.map(&:rstrip)
        return nil if t_lines.empty? || f_lines.empty?

        k = t_lines.size
        best_score = 0.0
        best_range = 1..1
        best_i = nil
        best_window_len = nil

        # PERF: memoize raw file lines once before loop to avoid re-splitting inside loop on score updates
        f_raw_lines = f_raw.lines

        # PERF: Pre-compute line membership and prefix sum array to prune window evaluations
        target_set = Set.new(t_lines)
        pref = Array.new(f_lines.size + 1, 0)
        f_lines.each_with_index { |l, idx| pref[idx + 1] = pref[idx] + (target_set.include?(l) ? 1 : 0) }

        (0...(f_lines.size)).each do |i|
          window_len = [k, f_lines.size - i].min
          total = [k, window_len].max

          overlap_count = pref[i + window_len] - pref[i]

          if k == 1 && window_len == 1
            window_line = f_lines[i]
            score = if overlap_count == 1
                      1.0
                    else
                      similarity_ratio(t_lines.first, window_line, min_threshold: best_score)
                    end
          else
            # PERF: Upper-bound check — if maximum possible overlap cannot beat best_score, skip LCS
            next if (overlap_count.to_f / total) <= best_score

            # PERF: Array#[start, len] slice avoids Range object allocation inside hot loop
            window = f_lines[i, window_len]

            matches =
              if defined?(Diff::LCS) && Diff::LCS.respond_to?(:LCS)
                Diff::LCS.LCS(t_lines, window).size
              else
                # Fallback line matching
                (0...[t_lines.size, window.size].min).count { |idx| t_lines[idx] == window[idx] }
              end
            score = total.positive? ? (matches.to_f / total) : 0.0
          end

          next unless score > best_score

          best_score = score
          best_range = (i + 1)..(i + window_len)
          best_i = i
          best_window_len = window_len
        end

        return nil if best_score < 0.25 || best_i.nil?

        # PERF: defer snippet string construction until after best match selection
        best_snippet = f_raw_lines[best_i, best_window_len].join

        {
          snippet: best_snippet.strip,
          range: best_range,
          similarity: (best_score * 100).round
        }
      end
    end
  end
end
