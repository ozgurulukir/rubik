# frozen_string_literal: true

require_relative "../test_helper"

# The partial-index disclosure contract (#357): success results served from
# an aborted scan carry the PARTIAL note; clean scans leave output unchanged.
class TestPartialIndexReporting < Minitest::Test
  # Duck-typed index carrying the status_summary keys the tools read.
  class FakeIndex
    attr_reader :files

    def initialize(files:, aborted: false, error: nil)
      @files = files
      @aborted = aborted
      @error = error
    end

    def status_summary
      { file_count: @files.size, languages: [], last_scan_time_sec: 0.0,
        last_scan_aborted: @aborted, last_scan_error: @error }
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    File.write(File.join(@temp_dir, "greeter.rb"), "class Greeter\n  def greet; 'hi'; end\nend\n")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_note_is_nil_for_clean_scan_and_populated_for_aborted
    assert_nil Rubik::Tools::IndexMessages.partial_index_note(false, nil)
    assert_nil Rubik::Tools::IndexMessages.partial_index_note(false, "boom")
    assert_nil Rubik::Tools::IndexMessages.partial_index_note(nil, nil)

    note = Rubik::Tools::IndexMessages.partial_index_note(true, "walk failed")
    assert_includes note, "PARTIAL"
    assert_includes note, "walk failed"
    assert_includes note, "!context scan"
  end

  def test_list_files_appends_note_on_partial_index
    idx = FakeIndex.new(files: { "greeter.rb" => { size: 1 } }, aborted: true, error: "boom")
    tool = Rubik::Tools::ListFilesTool.new(idx, root_dir: @temp_dir)

    res = tool.execute({}).to_s

    assert_includes res, "Found 1 file(s)"
    assert_includes res, "PARTIAL"
  end

  def test_list_files_no_match_from_partial_index_discloses_the_truncation
    idx = FakeIndex.new(files: { "greeter.rb" => { size: 1 } }, aborted: true, error: "boom")
    tool = Rubik::Tools::ListFilesTool.new(idx, root_dir: @temp_dir)

    res = tool.execute({ "path" => "nowhere" }).to_s

    assert_includes res, "No matching files"
    assert_includes res, "PARTIAL", "a flat no-match from a truncated index is the false-negative trap"
  end

  def test_list_files_clean_index_output_unchanged
    idx = FakeIndex.new(files: { "greeter.rb" => { size: 1 } })
    tool = Rubik::Tools::ListFilesTool.new(idx, root_dir: @temp_dir)

    res = tool.execute({}).to_s

    assert_includes res, "Found 1 file(s)"
    refute_includes res, "PARTIAL"
  end

  def test_grep_appends_note_on_hits_and_no_matches_when_partial
    idx = FakeIndex.new(files: { "greeter.rb" => { size: 1 } }, aborted: true, error: "boom")
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, idx, root_dir: @temp_dir,
                                                                  config: NativeOffStub.new)

    hits = tool.execute({ "query" => "greet" }).to_s
    assert_includes hits, "Found 2 match(es)"
    assert_includes hits, "PARTIAL"

    misses = tool.execute({ "query" => "nonexistent_token" }).to_s
    assert_includes misses, "No matching lines"
    assert_includes misses, "PARTIAL", "a no-match served from a partial index is the dangerous case"
  end

  def test_grep_clean_index_output_unchanged
    idx = FakeIndex.new(files: { "greeter.rb" => { size: 1 } })
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, idx, root_dir: @temp_dir,
                                                                  config: NativeOffStub.new)

    hits = tool.execute({ "query" => "greet" }).to_s

    assert_includes hits, "Found 2 match(es)"
    refute_includes hits, "PARTIAL"
  end

  # Minimal config double pinning the tool to the pure-Ruby search path.
  class NativeOffStub
    def fetch(_key, _default = nil)
      "off"
    end
  end
end
