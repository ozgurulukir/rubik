# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestTeeIOAnsiStrip < Minitest::Test
  def test_stringio_targets_receive_stripped_content
    capture = StringIO.new
    real = StringIO.new
    tee = Rubik::REPL::TeeIO.new(real, capture)

    tee.puts "\e[31mred line\e[0m"
    tee.print "\e[1mbold\e[0m tail"
    tee.write "\e[32mgreen\e[0m"

    assert_equal "red line\nbold tailgreen", capture.string
    assert_equal "red line\nbold tailgreen", real.string
  end

  def test_non_stringio_targets_keep_exact_content
    # A real IO target (File) must receive the colored bytes; only
    # StringIO capture targets are stripped.
    Dir.mktmpdir("rubik_tee") do |dir|
      File.open(File.join(dir, "real.log"), "w+") do |real|
        capture = StringIO.new
        tee = Rubik::REPL::TeeIO.new(real, capture)

        tee.puts "\e[31mkeep me colored\e[0m"
        tee.flush
        real.rewind

        assert_equal "\e[31mkeep me colored\e[0m\n", real.read
        assert_equal "keep me colored\n", capture.string
      end
    end
  end

  def test_plain_content_passes_untouched
    capture = StringIO.new
    tee = Rubik::REPL::TeeIO.new(StringIO.new, capture)
    tee.puts "plain line"
    assert_equal "plain line\n", capture.string
  end

  def test_existing_predicates_stay_stable
    capture = StringIO.new
    tee = Rubik::REPL::TeeIO.new(StringIO.new, capture)
    assert tee.string_io?
    assert tee.test_capture?
  end
end
