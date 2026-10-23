# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../../lib/rubik/context/git_lister"

class TestGitListerErrorHandling < Minitest::Test
  def test_git_lister_files_success
    files = Rubik::Context::GitLister.files(Dir.pwd)
    # If in a git repo, returns an array
    if files
      assert_kind_of Array, files
      assert files.any? { |f| f.include?("lib/rubik.rb") || f.include?("Gemfile") }
    end
  end

  def test_git_lister_files_handles_exception
    Open3.stub :capture3, ->(*_args) { raise StandardError, "git process crashed" } do
      res = Rubik::Context::GitLister.files(Dir.pwd)
      assert_nil res
    end
  end
end
