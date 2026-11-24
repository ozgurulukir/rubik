# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"

module Rubik
  module Buffer
    class Diff
      # Line diffs are only meaningful for text. Binary buffers (issue #628)
      # get a placeholder instead of a fake diff produced by scrubbing away
      # the very bytes that differ.
      def self.unified_diff(file_path, original_content, new_content, context: 3)
        binary = binary?(original_content) || binary?(new_content)
        return "Binary files a/#{file_path} and b/#{file_path} differ\n" if binary

        orig_lines = text_lines(original_content)
        new_lines = text_lines(new_content)

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

      # Diff::LCS compares strings by encoding; binary-safe reads can hand
      # it ASCII-8BIT on one side and UTF-8 on the other. Normalize to valid
      # UTF-8 for DISPLAY only — hashing and apply use the untouched bytes.
      def self.text_lines(content)
        text = (content || "").to_s
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        text = text.scrub("") unless text.valid_encoding?
        text.lines
      end

      def self.binary?(content)
        return false unless content.is_a?(String)

        bytes = content.b
        return true if bytes.include?("\x00".b)

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return false if text.valid_encoding?

        # A lone bad byte in an otherwise textual file stays diffable
        # (legacy UTF-8 recovery). Two or more signal binary content where
        # scrubbing would fabricate a meaningless diff (issue #628).
        bytes.bytesize - text.scrub("").bytesize > 1
      end
      private_class_method :text_lines, :binary?
    end
  end
end
