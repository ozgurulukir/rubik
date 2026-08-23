# frozen_string_literal: true

require "tempfile"

module Rubik
  module Buffer
    class Diff
      def self.unified_diff(file_path, original_content, new_content)
        orig_lines = (original_content || "").lines
        new_lines = (new_content || "").lines

        return "" if orig_lines == new_lines

        header = [
          "--- a/#{file_path}",
          "+++ b/#{file_path}"
        ]

        hunk = build_hunk(orig_lines, new_lines)
        (header + hunk).join("\n") + "\n"
      end

      def self.build_hunk(orig_lines, new_lines)
        result = []
        result << "@@ -1,#{orig_lines.size} +1,#{new_lines.size} @@"

        orig_lines.each do |line|
          result << "-#{line.chomp}"
        end
        new_lines.each do |line|
          result << "+#{line.chomp}"
        end

        result
      end
    end
  end
end
