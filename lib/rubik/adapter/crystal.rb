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

      private

      # Nearest ancestor of the target (or the session root) that carries a
      # shard.yml — crystal resolves shard dependencies from that directory,
      # so a repo with a nested shard root (e.g. cli/shard.yml) must run its
      # specs from there, not from the session root. nil = no shard root
      # found; the default session-root behavior applies.
      def shard_root(root_dir, path)
        clean = path.to_s.strip
        start = clean.empty? ? root_dir : File.dirname(File.expand_path(clean, root_dir))
        walk = start.tr("\\", "/")
        until walk.empty? || walk == File.dirname(walk)
          return walk if File.exist?(File.join(walk, "shard.yml"))

          walk = File.dirname(walk)
        end
        root = root_dir.to_s.tr("\\", "/")
        File.exist?(File.join(root, "shard.yml")) ? root : nil
      end

      public

      # Relativize the targeted spec path to the shard root so the command
      # and the working directory (test_working_dir) agree on the same base.
      # Prefix match is case-insensitive (Windows filesystems); the strip is
      # exact-token based on the raw expanded path — Platform.normalize_path
      # downcases on Windows and would corrupt the rendered path.
      def resolve_test_cmd(root_dir = Dir.pwd, path: nil)
        clean = path.to_s.strip
        unless clean.empty? || (root = shard_root(root_dir, clean)).nil?
          abs = File.expand_path(clean, root_dir).tr("\\", "/")
          prefix = root.end_with?("/") ? root : "#{root}/"
          clean = abs.downcase.start_with?(prefix.downcase) ? abs[prefix.length..] : abs
        end
        super(root_dir, path: clean.empty? ? nil : clean)
      end

      def test_working_dir(root_dir, path)
        shard_root(root_dir, path) || super
      end
    end
  end
end
