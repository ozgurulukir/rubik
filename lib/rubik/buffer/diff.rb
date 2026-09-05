# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"

module Rubik
  module Buffer
    class Diff
      def self.unified_diff(file_path, original_content, new_content, context: 3)
        orig_lines = (original_content || "").lines
        new_lines = (new_content || "").lines

        return "" if orig_lines == new_lines

        diffs = ::Diff::LCS.diff(orig_lines, new_lines)
        return "" if diffs.empty?

        output = "--- a/#{file_path}\n+++ b/#{file_path}\n"
        file_length_difference = 0
        oldhunk = hunk = nil

        diffs.each do |piece|
          hunk = ::Diff::LCS::Hunk.new(orig_lines, new_lines, piece, context, file_length_difference)
          file_length_difference = hunk.file_length_difference
          next unless oldhunk
          next if context.positive? && hunk.overlaps?(oldhunk) && hunk.merge(oldhunk)

          output << oldhunk.diff(:unified) << "\n"
        ensure
          oldhunk = hunk
        end

        if oldhunk
          last = oldhunk.diff(:unified, true)
          last << "\n" unless last.empty? || last.end_with?("\n")
          output << last
        end

        output
      end
    end
  end
end
