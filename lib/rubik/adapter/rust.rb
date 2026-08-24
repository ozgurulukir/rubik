# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class RustAdapter < BaseAdapter
      def initialize
        super("rust", "cargo")
      end

      def check_syntax(_file_path)
        return unavailable_result unless available?
        ProcessRunner.run("cargo check")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("cargo build", chdir: root_dir)
      end

      protected

      def default_test_cmd
        "cargo test"
      end

      def default_format_cmd(file_path)
        "rustfmt #{Shellwords.escape(file_path)}"
      end
    end
  end
end
