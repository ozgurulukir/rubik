# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class ZigAdapter < BaseAdapter
      def initialize
        super("zig", "zig")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("zig build-exe -fno-emit-bin #{Shellwords.escape(file_path)}")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("zig build", chdir: root_dir)
      end

      protected

      def default_test_cmd
        "zig test"
      end

      def default_format_cmd(file_path)
        "zig fmt #{Shellwords.escape(file_path)}"
      end
    end
  end
end
