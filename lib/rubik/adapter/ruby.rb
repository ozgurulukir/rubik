# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class RubyAdapter < BaseAdapter
      def initialize
        super("ruby", "ruby")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("ruby -c #{Shellwords.escape(file_path)}")
      end

      def compile(_root_dir)
        { ok: true, output: "Ruby is interpreted (no compilation required)", duration: 0.0, exit_code: 0 }
      end

      protected

      def default_test_cmd
        "rake test"
      end

      def default_format_cmd(file_path)
        "rubocop -a #{Shellwords.escape(file_path)}"
      end
    end
  end
end
