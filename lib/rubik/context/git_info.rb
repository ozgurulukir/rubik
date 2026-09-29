# frozen_string_literal: true

require "open3"
require "shellwords"

module Rubik
  module Context
    class GitInfo
      attr_reader :root_dir

      def initialize(root_dir: Dir.pwd, process_runner: nil)
        @root_dir = File.expand_path(root_dir)
        @process_runner = process_runner || method(:default_runner)
      end

      def git_repo?
        !git_dir.nil?
      end

      def active_branch
        dir = git_dir
        return nil unless dir

        head_file = File.join(dir, "HEAD")
        return nil unless File.exist?(head_file)

        content = Rubik::Platform.read_text(head_file).strip
        return nil if content.empty?

        if content.start_with?("ref: refs/heads/")
          content.sub("ref: refs/heads/", "")
        else
          content[0..6]
        end
      rescue SystemCallError, ArgumentError
        # ArgumentError: expand_path over hostile .git-file content (NUL, bad tilde)
        nil
      end

      def status
        return { git: false } unless git_repo?

        out, code = run_git("status --porcelain")
        return { git: false } unless code.zero?

        dirty = !out.strip.empty?
        {
          git: true,
          branch: active_branch,
          dirty: dirty
        }
      end

      private

      # The .git entry can be a directory (normal clone) or a FILE holding
      # "gitdir: <path>" (linked worktree / submodule). Returns the directory
      # that owns HEAD either way, or nil when the root is not a checkout.
      def git_dir
        dot_git = File.join(@root_dir, ".git")
        if File.directory?(dot_git)
          dot_git
        elsif File.file?(dot_git)
          target = Rubik::Platform.read_text(dot_git).strip.delete_prefix("gitdir:").strip
          File.expand_path(target, @root_dir) unless target.empty?
        end
      rescue SystemCallError, ArgumentError
        nil
      end

      def default_runner(cmd)
        args = cmd.is_a?(Array) ? cmd : Shellwords.split(cmd.to_s)
        out, status = Open3.capture2e("git", "-C", @root_dir, *args)
        [out, status.exitstatus || 1]
      rescue StandardError
        ["", 1]
      end

      def run_git(cmd)
        @process_runner.call(cmd)
      end
    end
  end
end
