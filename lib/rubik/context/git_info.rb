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
        File.directory?(File.join(@root_dir, ".git"))
      end

      def active_branch
        return nil unless git_repo?

        head_file = File.join(@root_dir, ".git", "HEAD")
        return nil unless File.exist?(head_file)

        content = Rubik::Platform.read_text(head_file).strip
        if content.start_with?("ref: refs/heads/")
          content.sub("ref: refs/heads/", "")
        else
          content[0..6]
        end
      rescue StandardError
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
