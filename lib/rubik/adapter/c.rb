# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class CAdapter < BaseAdapter
      def initialize
        super("c", "clang")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("clang -fsyntax-only #{Shellwords.escape(file_path)}")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("make", chdir: root_dir)
      end

      protected

      def default_test_cmd
        "ctest"
      end

      def default_format_cmd(file_path)
        "clang-format -i #{Shellwords.escape(file_path)}"
      end
    end
  end
end
