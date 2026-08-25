# frozen_string_literal: true

require_relative "../test_helper"

# Tests for PR-J: PROTOCOL_CANDIDATES moved out of ContextBuilder.
# The single source of truth is now in
# Rubik::Context::RepoContextReader::DEFAULT_PROTOCOL_CANDIDATES.
class TestProtocolCandidatesLocation < Minitest::Test
  def test_context_builder_no_longer_defines_protocol_candidates
    src = File.read("lib/rubik/prompt/context_builder.rb")
    refute_match(/^\s*PROTOCOL_CANDIDATES\s*=/, src,
                 "ContextBuilder must not define PROTOCOL_CANDIDATES")
  end

  def test_context_builder_no_longer_references_protocol_candidates
    src = File.read("lib/rubik/prompt/context_builder.rb")
    refute_match(/PROTOCOL_CANDIDATES/, src,
                 "ContextBuilder must not reference PROTOCOL_CANDIDATES")
  end

  def test_repo_context_reader_defines_default_protocol_candidates
    assert defined?(Rubik::Context::RepoContextReader::DEFAULT_PROTOCOL_CANDIDATES)
    candidates = Rubik::Context::RepoContextReader::DEFAULT_PROTOCOL_CANDIDATES
    assert_kind_of Array, candidates
    assert_includes candidates, "AGENTS.md"
  end

  def test_default_protocol_candidates_are_frozen
    candidates = Rubik::Context::RepoContextReader::DEFAULT_PROTOCOL_CANDIDATES
    assert candidates.frozen?, "DEFAULT_PROTOCOL_CANDIDATES should be frozen"
  end

  def test_no_active_references_in_lib_outside_reader
    # PROTOCOL_CANDIDATES should only be actively referenced in the
    # repo context reader. Comments referencing the moved constant
    # are fine (they help anyone grepping the codebase find the new
    # location), but no code path should still try to use it.
    output = `grep -rn "PROTOCOL_CANDIDATES" lib/`.strip
    # Skip comment lines (starting with #) and the reader file
    active_files = output.lines.reject { |l| l.include?("#") }
                               .map { |l| l.split(":").first }
                               .uniq
    assert_equal ["lib/rubik/context/repo_context_reader.rb"], active_files,
                 "PROTOCOL_CANDIDATES should only be actively used in repo_context_reader.rb, found in #{active_files.inspect}"
  end
end
