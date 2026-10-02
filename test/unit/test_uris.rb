# frozen_string_literal: true

require_relative "../test_helper"

# Rubik::Uris gramer yaprağı (uri-resolver-seam planı 2026-10-01):
# desenler, çözümleyiciler ve kurucular tek evde; kurucular ayrıştırıcılardan
# geçmeli (yuvarak gezi), ref sözleşimi "subagent-<storage-id>" sabitlenmiş.
class TestUris < Minitest::Test
  def test_storage_path_strips_prefix_for_bare_root_and_trailing_forms
    assert_equal "", Rubik::Uris.storage_path("rubik://storage"),
                 "bare root strips to the empty path (UriReader reports it malformed)"
    assert_equal "", Rubik::Uris.storage_path("RUBIK://Storage"), "the strip is case-insensitive like the historical regex"
    assert_equal "goal/1", Rubik::Uris.storage_path("rubik://storage/goal/1")
    assert_equal "uriproj/refs/alias", Rubik::Uris.storage_path("rubik://storage/uriproj/refs/alias")
    assert_nil Rubik::Uris.storage_path("rubik://storagefoo"), "prefix demands a slash or end-of-string"
    assert_nil Rubik::Uris.storage_path("lib/main.rb")
  end

  def test_builders_round_trip_through_the_parsers
    entity = Rubik::Uris.storage_entity(project: "uriproj", type: "goal", id: "goal.1.9f86d081884c7d21")
    assert_equal "rubik://storage/uriproj/goal/goal.1.9f86d081884c7d21", entity
    assert_equal "uriproj/goal/goal.1.9f86d081884c7d21", Rubik::Uris.storage_path(entity),
                 "storage_entity output must survive the canonical strip"

    transcript_uri = Rubik::Uris.subagent_transcript("sid-42")
    assert_equal "rubik://subagent/sid-42/transcript", transcript_uri
    assert_equal "sid-42", transcript_uri[Rubik::Uris::SUBAGENT_TRANSCRIPT, 1],
                 "subagent_transcript output must carry the storage id the transcript reader captures"

    assert_equal "rubik://goal/state", Rubik::Uris.goal_state
    assert Rubik::Uris::GOAL_STATE.match?(Rubik::Uris.goal_state)
    assert_equal "rubik://storage/uriproj/goal", Rubik::Uris.storage_listing(project: "uriproj", type: "goal")
    assert_equal "rubik://storage/index", Rubik::Uris.storage_index
  end

  def test_transcript_ref_uses_the_subagent_prefix_convention
    assert_equal "subagent-sid-7", Rubik::Uris.transcript_ref("sid-7")
    assert_equal "subagent-", Rubik::Uris::TRANSCRIPT_REF_PREFIX
  end

  def test_scheme_of_extracts_case_insensitively_and_returns_nil_for_plain_paths
    assert_equal "storage", Rubik::Uris.scheme_of("rubik://storage/index")
    assert_equal "goal", Rubik::Uris.scheme_of("RUBIK://Goal/state")
    assert_equal "subagent", Rubik::Uris.scheme_of("rubik://subagent/sid-1/transcript")
    assert_equal "storagefoo", Rubik::Uris.scheme_of("rubik://storagefoo"), "unknown schemes are named, not nil"
    assert_nil Rubik::Uris.scheme_of("lib/main.rb")
    assert_nil Rubik::Uris.scheme_of("file:///C:/work/main.rb")
  end

  def test_storage_relative_is_the_cosmetic_display_strip
    assert_equal "proj/goal/1", Rubik::Uris.storage_relative("rubik://storage/proj/goal/1")
    assert_equal "proj/goal/1", Rubik::Uris.storage_relative("RUBIK://storage/proj/goal/1")
    assert_nil Rubik::Uris.storage_relative("rubik://storage"), "no trailing slash → nothing to show"
    assert_nil Rubik::Uris.storage_relative("lib/main.rb")
  end
end
