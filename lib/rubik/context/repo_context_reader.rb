# frozen_string_literal: true

require "fileutils"

module Rubik
  module Context
    # Reads repository-level context that the Prompt layer would otherwise
    # have to handle inline. Pulls filesystem reads out of ContextBuilder so
    # the prompt layer is a pure data-transformation layer (no I/O).
    #
    # Usage:
    #   reader = Rubik::Context::RepoContextReader.new(root_dir: Dir.pwd)
    #   ctx = reader.read  # => { protocol_xml:, workspace_summary:, git_branch: }
    #
    # All methods are safe to call on a non-git / empty directory; they
    # return nil / empty values rather than raising.
    class RepoContextReader
      DEFAULT_PROTOCOL_CANDIDATES = %w[
        AGENTS.md
        .rubik/AGENTS.md
        RULES.md
        CLAUDE.md
        .cursorrules
      ].freeze

      # Entry-point filenames that the workspace-summary considers worth
      # surfacing when the file count is large.
      ENTRY_POINT_BASENAMES = %w[
        Gemfile package.json Cargo.toml go.mod Makefile pyproject.toml
        Rakefile index.html README.md
      ].freeze

      def initialize(root_dir: Dir.pwd, protocol_candidates: DEFAULT_PROTOCOL_CANDIDATES)
        @root_dir = root_dir
        @protocol_candidates = protocol_candidates
      end

      # Returns a Hash with three keys, each pre-extracted and pre-rendered
      # so the prompt layer never has to touch the filesystem.
      def read
        {
          protocol_xml: read_protocol_xml,
          workspace_summary: read_workspace_summary,
          git_branch: read_git_branch
        }
      end

      # List of files that match the protocol-file candidates.
      def find_protocol_files
        @protocol_candidates.filter_map do |candidate|
          full_path = File.join(@root_dir, candidate)
          { path: candidate, full_path: full_path } if File.file?(full_path)
        end
      end

      # Render the matched protocol files into an XML block.
      def read_protocol_xml
        files = find_protocol_files
        return "" if files.empty?

        files.map do |f|
          content = File.read(f[:full_path]).strip
          <<~XML
            <protocol source="#{f[:path]}">
            #{content}
            </protocol>
          XML
        end.join("\n").strip
      end

      # Returns a Hash describing the project layout. The prompt layer
      # can decide how to render it (the existing `build_workspace_xml`
      # in ContextBuilder does, and the new path can be passed in).
      def read_workspace_summary
        {
          project_name: File.basename(@root_dir),
          file_count: nil,        # filled in by the caller's context_index
          languages: [],          # filled in by the caller's context_index
          files: {}               # filled in by the caller's context_index
        }
      end

      # Read the current git branch from .git/HEAD. Returns nil if not a
      # git repo, or the repo is in detached-HEAD state.
      def read_git_branch
        git_dir = File.join(@root_dir, ".git")
        return nil unless File.directory?(git_dir)

        head_file = File.join(git_dir, "HEAD")
        return nil unless File.exist?(head_file)

        content = File.read(head_file).strip
        return nil if content.empty?

        # HEAD is either a ref like "ref: refs/heads/main" or a raw SHA
        prefix = "ref: refs/heads/"
        if content.start_with?(prefix)
          content[prefix.length..]
        else
          # detached HEAD: return the raw SHA
          content
        end
      end
    end
  end
end
