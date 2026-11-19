# frozen_string_literal: true

require_relative "../test_helper"

# Issue #589: `!diff` must read the on-disk original through
# Buffer::Manager.read(rel, from_disk: true) so both diff operands share the
# read_bytes_as_utf8 encoding; a plain File.read can raise
# Encoding::CompatibilityError for files with invalid-UTF-8 bytes.
class TestBufferDiffCommand < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @out = StringIO.new
    @shell = Struct.new(:buffer_manager, :theme, :out, :output, :input).new(
      @manager,
      Rubik::UI::Theme.new(enabled: false),
      @out,
      @out,
      StringIO.new
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_handle_diff_reads_disk_side_with_utf8_recovery
    rel = "blob.rb"
    File.binwrite(File.join(@temp_dir, rel), "caf\xE9 old\n".b)
    @manager.read(rel)
    @manager.write(rel, "café new\n")

    Rubik::REPL::Commands::Buffer.send(:handle_diff, [rel], @shell)

    output = @out.string
    assert_includes output, "-caf", "diff must show the on-disk original"
    assert_includes output, "+café new"
  rescue Encoding::CompatibilityError
    flunk "!diff raised Encoding::CompatibilityError on invalid-UTF-8 disk content"
  end
end
