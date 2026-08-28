# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class PythonAdapter < BaseAdapter
      def initialize
        super("python", "python3")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("python3 -m py_compile #{Shellwords.escape(file_path)}")
      end

      protected

      def default_test_cmd
        "pytest"
      end

      def default_format_cmd(file_path)
        "ruff format #{Shellwords.escape(file_path)}"
      end
    end
  end
end
