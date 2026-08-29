# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

# Tests for PR-G: Rubik::Context::RepoContextReader.
# Pulls filesystem reads out of ContextBuilder so the prompt layer
# is a pure data-transformation layer.
class TestRepoContextReader < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_repo_ctx_test")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def write(path, content)
    full = File.join(@tmp, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  # ---------- find_protocol_files ----------

  def test_find_protocol_files_finds_default_candidates
    write("AGENTS.md", "default protocol content")
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    files = reader.find_protocol_files
    assert_equal 1, files.size
    assert_equal "AGENTS.md", files[0][:path]
  end

  def test_find_protocol_files_returns_multiple_when_several_exist
    write("AGENTS.md", "agents")
    write("RULES.md", "rules")
    write("CLAUDE.md", "claude")
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    files = reader.find_protocol_files
    paths = files.map { |f| f[:path] }
    assert_includes paths, "AGENTS.md"
    assert_includes paths, "RULES.md"
    assert_includes paths, "CLAUDE.md"
  end

  def test_find_protocol_files_returns_empty_when_none_exist
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    assert_empty reader.find_protocol_files
  end

  def test_find_protocol_files_respects_custom_candidates
    write("MY_RULES.md", "x")
    reader = Rubik::Context::RepoContextReader.new(
      root_dir: @tmp,
      protocol_candidates: ["MY_RULES.md"]
    )
    files = reader.find_protocol_files
    assert_equal 1, files.size
    assert_equal "MY_RULES.md", files[0][:path]
  end

  # ---------- read_protocol_xml ----------

  def test_read_protocol_xml_renders_blocks
    write("AGENTS.md", "follow these rules")
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    xml = reader.read_protocol_xml
    assert_includes xml, "<protocol source=\"AGENTS.md\">"
    assert_includes xml, "follow these rules"
    assert_includes xml, "</protocol>"
  end

  def test_read_protocol_xml_returns_empty_string_when_no_files
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    assert_equal "", reader.read_protocol_xml
  end

  # ---------- read_git_branch ----------

  def test_read_git_branch_returns_nil_when_no_git_dir
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    assert_nil reader.read_git_branch
  end

  def test_read_git_branch_returns_nil_when_no_head_file
    FileUtils.mkdir_p(File.join(@tmp, ".git"))
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    assert_nil reader.read_git_branch
  end

  def test_read_git_branch_parses_ref_format
    FileUtils.mkdir_p(File.join(@tmp, ".git"))
    File.write(File.join(@tmp, ".git/HEAD"), "ref: refs/heads/main\n")
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    assert_equal "main", reader.read_git_branch
  end

  def test_read_git_branch_returns_raw_sha_in_detached_head
    FileUtils.mkdir_p(File.join(@tmp, ".git"))
    File.write(File.join(@tmp, ".git/HEAD"), "abc123def456abc123def456abc123def4567890\n")
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    assert_equal "abc123def456abc123def456abc123def4567890", reader.read_git_branch
  end

  # ---------- read (composite) ----------

  def test_read_returns_all_three_keys
    write("AGENTS.md", "x")
    FileUtils.mkdir_p(File.join(@tmp, ".git"))
    File.write(File.join(@tmp, ".git/HEAD"), "ref: refs/heads/feature-foo\n")
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    result = reader.read
    assert_equal 3, result.keys.size
    assert_includes result[:protocol_xml], "<protocol"
    assert_includes result[:workspace_summary][:project_name], "rubik_repo_ctx_test"
    assert_equal "feature-foo", result[:git_branch]
  end

  def test_read_returns_safe_defaults_on_empty_repo
    reader = Rubik::Context::RepoContextReader.new(root_dir: @tmp)
    result = reader.read
    assert_equal "", result[:protocol_xml]
    assert_nil result[:git_branch]
    assert_equal File.basename(@tmp), result[:workspace_summary][:project_name]
  end
end
