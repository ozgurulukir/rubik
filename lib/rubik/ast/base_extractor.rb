# frozen_string_literal: true

require_relative "symbol"
require_relative "body_loader"

module Rubik
  module AST
    module BaseExtractor
      def self.included(base)
        base.include(BodyLoader)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def extract(file_path, content = nil)
          new(file_path, content).extract
        end
      end

      def initialize(file_path, content = nil)
        @file_path = file_path
        @content = content || (File.exist?(file_path) ? File.read(file_path) : "")
        @lines = @content.lines
      end

      private

      def find_closing_brace(start_idx)
        brace_count = 0
        found_open = false

        (start_idx..(@lines.size - 1)).each do |idx|
          line = @lines[idx]
          line.each_char do |char|
            if char == "{"
              brace_count += 1
              found_open = true
            elsif char == "}"
              brace_count -= 1
            end
          end

          return idx + 1 if found_open && brace_count <= 0
        end

        found_open ? @lines.size : start_idx + 1
      end

      def extract_lines(start_line, end_line)
        s_idx = [start_line - 1, 0].max
        e_idx = [end_line - 1, @lines.size - 1].min
        @lines[s_idx..e_idx].join
      end
    end
  end
end
