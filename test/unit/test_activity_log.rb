# frozen_string_literal: true

require_relative "../test_helper"

class TestActivityLog < Minitest::Test
  def setup
    @log = Rubik::Orchestrator::ActivityLog.new
  end

  # ── Recording ──────────────────────────────────────────────────────

  def test_records_tool_usage_counts
    @log.record("read_file", { "path" => "lib/main.rb" }, :ok)
    @log.record("read_file", { "path" => "lib/main.rb" }, :ok)
    @log.record("write_file", { "path" => "lib/output.rb" }, :ok)

    summary = @log.summary
    assert_includes summary, "read_file(x2)"
    assert_includes summary, "write_file"
  end

  def test_records_file_paths_up_to_ten_unique
    15.times do |i|
      @log.record("read", { "path" => "file_#{i}.rb" }, :ok)
    end
    summary = @log.summary
    assert_includes summary, "Files touched"
    # At most 10 unique paths
    touched_count = summary.scan(/file_\d+\.rb/).size
    assert_equal 10, touched_count
  end

  def test_deduplicates_file_paths
    @log.record("read", { "path" => "a.rb" }, :ok)
    @log.record("write", { "path" => "a.rb" }, :ok)
    summary = @log.summary
    assert_equal 1, summary.scan("a.rb").size
  end

  def test_records_tool_errors
    @log.record("read_file", { "path" => "missing.rb" }, :error)
    summary = @log.summary
    assert_includes summary, "Tool errors encountered: 1"
  end

  def test_no_error_count_when_zero_errors
    @log.record("read_file", { "path" => "ok.rb" }, :ok)
    summary = @log.summary
    refute_includes summary, "Tool errors"
  end

  def test_records_with_symbol_keys
    @log.record("write", { path: "sym_key.rb" }, :ok)
    summary = @log.summary
    assert_includes summary, "sym_key.rb"
  end

  # ── Summary with buffer manager ────────────────────────────────────

  def test_summary_includes_dirty_files_when_buffer_dirty
    temp_dir = Dir.mktmpdir
    begin
      bm = Rubik::Buffer::Manager.new(root_dir: temp_dir)
      bm.write("dirty.rb", "new content")

      summary = @log.summary(bm)
      assert_includes summary, "Unapplied buffer changes"
      assert_includes summary, "dirty.rb"
    ensure
      FileUtils.remove_entry(temp_dir)
    end
  end

  def test_summary_omits_buffer_section_when_clean
    temp_dir = Dir.mktmpdir
    begin
      bm = Rubik::Buffer::Manager.new(root_dir: temp_dir)
      summary = @log.summary(bm)
      refute_includes summary, "Unapplied buffer changes"
    ensure
      FileUtils.remove_entry(temp_dir)
    end
  end

  def test_summary_with_nil_buffer_manager_does_not_crash
    @log.record("read", { "path" => "a.rb" }, :ok)
    assert_kind_of String, @log.summary(nil)
  end

  # ── Reset ──────────────────────────────────────────────────────────

  def test_reset_clears_all_state
    @log.record("write", { "path" => "a.rb" }, :ok)
    @log.record("read", { "path" => "b.rb" }, :error)
    refute_empty @log.summary

    @log.reset!
    assert_empty @log.summary
  end

  def test_reset_clears_tool_errors
    @log.record("write", { "path" => "a.rb" }, :error)
    @log.reset!
    summary = @log.summary
    refute_includes summary, "Tool errors"
  end

  # ── Edge cases ─────────────────────────────────────────────────────

  def test_empty_log_returns_empty_string
    assert_equal "", @log.summary
  end

  def test_record_handles_malformed_path_gracefully
    @log.record("write", { "path" => nil }, :ok)
    summary = @log.summary
    # Tool is recorded but the nil path is skipped
    refute_includes summary, "nil"
  end

  def test_tool_error_from_hash_status_symbol
    @log.record("write", { "path" => "a.rb" }, :error)
    @log.record("read", { "path" => "b.rb" }, :ok)
    summary = @log.summary
    assert_includes summary, "Tool errors encountered: 1"
  end
end
