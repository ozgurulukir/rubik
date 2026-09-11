# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class CrystalAdapter < BaseAdapter
      def initialize
        super("crystal", "crystal")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?

        ProcessRunner.run("crystal build --no-codegen #{Shellwords.escape(file_path)}")
      end

      def compile(root_dir)
        return unavailable_result unless available?

        cmd = File.exist?(File.join(root_dir, "shard.yml")) ? "shards build" : "crystal build"
        ProcessRunner.run(cmd, chdir: root_dir)
      end

      protected

      def default_test_cmd
        "crystal spec"
      end

      def default_format_cmd(file_path)
        "crystal tool format #{Shellwords.escape(file_path)}"
      end
    end
  end
end
