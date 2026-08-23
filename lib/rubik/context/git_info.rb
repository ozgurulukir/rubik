# frozen_string_literal: true

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

        content = File.read(head_file).strip
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
        return { git: false } unless code == 0

        dirty = !out.strip.empty?
        {
          git: true,
          branch: active_branch,
          dirty: dirty
        }
      end

      private

      def default_runner(cmd)
        out = `git -C "#{Shellwords.escape(@root_dir)}" #{cmd} 2>&1`
        [out, $?.exitstatus]
      rescue StandardError
        ["", 1]
      end

      def run_git(cmd)
        @process_runner.call(cmd)
      end
    end
  end
end
