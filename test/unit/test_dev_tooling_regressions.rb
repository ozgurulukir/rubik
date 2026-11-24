# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

# Regression for #639 bullet 2: the profiler writes 4 CSV columns
# (wall,status,path,summary) but its final report split on 3, gluing the
# summary onto the path column. Verify the report prints the path alone.
class TestDevToolingRegressions < Minitest::Test
  def test_profiler_report_separates_path_from_summary
    Dir.mktmpdir("rubik_profiler_report") do |dir|
      FileUtils.mkdir_p(File.join(dir, "test/unit"))
      File.write(File.join(dir, "test/unit/test_fake.rb"), "# fake\n")
      FileUtils.mkdir_p(File.join(dir, "_report"))
      summary = "1 runs; 2 assertions; 0 failures; 0 errors; 0 skips"
      File.write(File.join(dir, "_report/unit_profile.csv"),
                 "9.50,OK,test/unit/test_fake.rb,#{summary}\n")

      script = File.expand_path("../../dev/profile_unit_tests.rb", __dir__)
      stdout, stderr, status = Open3.capture3({}, RbConfig.ruby, script, chdir: dir)

      assert status.success?, "profiler failed: #{stderr}"
      assert_includes stdout, "test/unit/test_fake.rb"
      refute_includes stdout, summary, "summary must not be glued to the path column"
      assert_includes stdout, "TOTAL serial wall: 9.5s across 1 files"
    end
  end

  def test_shared_wait_until_accepts_keyword_timeout_form
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = wait_until(timeout: 0.2, step: 0.01) { true }
    assert result
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  end
end
