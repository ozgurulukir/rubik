# frozen_string_literal: true

module Rubik
  module Diagnostics
    class Entry
      CATEGORIES = %i[syntax type undefined_ref memory_safety test_failure lint unknown].freeze

      attr_reader :file, :line, :col, :severity, :code, :message, :category, :raw_text

      def initialize(file: nil, line: nil, col: nil, severity: :error, code: nil, message: "", category: :unknown, raw_text: "")
        @file = file
        @line = line ? line.to_i : nil
        @col = col ? col.to_i : nil
        @severity = severity.to_sym
        @code = code
        @message = message.to_s.strip
        @category = CATEGORIES.include?(category.to_sym) ? category.to_sym : :unknown
        @raw_text = raw_text
      end

      def to_h
        {
          file: @file,
          line: @line,
          col: @col,
          severity: @severity,
          code: @code,
          message: @message,
          category: @category
        }
      end

      def format_prompt_snippet(graph = nil, root_dir = Dir.pwd)
        lines = []
        lines << "Diagnostic [#{@category.upcase}]: #{@message}"
        lines << "File: #{@file}:#{@line}:#{@col}" if @file && @line

        if @file && @line && File.exist?(File.join(root_dir, @file))
          file_content = File.read(File.join(root_dir, @file)).lines
          start_line = [@line - 10, 0].max
          end_line = [@line + 10, file_content.size - 1].min

          lines << "Context Snippet:"
          (start_line..end_line).each do |idx|
            prefix = (idx + 1) == @line ? "=> " : "   "
            lines << "#{prefix}#{idx + 1}: #{file_content[idx]}"
          end
        end

        lines.join("\n")
      end
    end
  end
end
