# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../../lib/rubik/tools/truncator"
require_relative "../../lib/rubik/tools/builtins/grep"
require_relative "../../lib/rubik/context/scanner"
require_relative "../../lib/rubik/context/index"
require_relative "../../lib/rubik/platform"
require_relative "../../lib/rubik/buffer/manager"

# Encoding hygiene contract for the tool-output and project-file pipeline
# (root-cause fix for the grep_search ArgumentError session failure):
#
#   tool output > Truncator byte cut splitting a multibyte char
#   -> invalid UTF-8 -> JSON.generate GeneratorError / regex ArgumentError
#
# Every fixture here is deliberately invalid UTF-8; each test asserts the
# OUTPUT is valid UTF-8 and downstream string ops do not raise.
class TestUtf8PipelineHygiene < Minitest::Test
  class NativeOffConfig
    def fetch(_key, _default = nil)
      "off"
    end
  end

  def test_truncator_head_tail_byte_cut_produces_valid_utf8
    # 6000 valid bytes; head_tail with max_chars 12000 -> half_chars 6000,
    # so head_str.bytesize > half_chars is false (equal) — force a cut with
    # 5999 bytes: the cut lands INSIDE the last 2-byte é.
    s = "#{'é' * 2999}x" # 5999 bytes, é at bytes 0..5997 + x
    res = Rubik::Tools::Truncator.truncate(s, max_chars: 5998, max_lines: 300, strategy: :head_tail)
    assert res[:text].valid_encoding?, "head_tail byte-cut produced invalid UTF-8"
    assert_includes res[:text], "Truncated:"
  end

  def test_truncator_head_only_byte_cut_produces_valid_utf8
    s = "é" * 3000 # 6000 bytes
    res = Rubik::Tools::Truncator.truncate(s, max_chars: 5999, max_lines: 300, strategy: :head_only)
    assert res[:text].valid_encoding?, "head_only byte-cut produced invalid UTF-8"
    idx = res[:text].index("\n... [Truncated")
    body = idx ? res[:text][0...idx] : res[:text]
    # notice reports the single dropped byte.
    assert_equal "é" * 2999, body
  end

  def test_truncator_tail_only_byte_cut_produces_valid_utf8
    s = "x#{'é' * 3000}" # 6001 bytes
    res = Rubik::Tools::Truncator.truncate(s, max_chars: 6000, max_lines: 300, strategy: :tail_only)
    assert res[:text].valid_encoding?, "tail_only byte-cut produced invalid UTF-8"
  end

  def test_truncator_survives_pre_broken_input
    invalid = "café \xFF data".dup.force_encoding(Encoding::UTF_8)
    res = Rubik::Tools::Truncator.truncate(invalid * 100)
    assert res[:text].valid_encoding?, "pre-broken input must be scrubbed at entry"
  end

  def test_grep_query_with_invalid_utf8_does_not_raise
    bad = "ok \xC3( bad".dup.force_encoding(Encoding::UTF_8)
    tool = Rubik::Tools::GrepSearchTool.new(nil, nil, root_dir: ".")
    result = tool.execute({ "query" => bad }) # no files -> "No matching lines"
    assert_instance_of String, result
    assert result.valid_encoding?
  end

  def test_grep_invalid_bytes_in_file_line_does_not_raise
    Dir.mktmpdir do |temp_dir|
      # cp1254 fixture: 0xFC is ü in cp1254, invalid as a UTF-8 start byte
      File.binwrite(File.join(temp_dir, "bad_enc.rb"), "x = \"caf\xFC\"\n  def foo; end\n")
      buffer = Rubik::Buffer::Manager.new(root_dir: temp_dir)
      idx = Rubik::Context::Index.new(root_dir: temp_dir, native: "off")
      tool = Rubik::Tools::GrepSearchTool.new(buffer, idx, root_dir: temp_dir, config: NativeOffConfig.new)
      res = tool.execute({ "query" => "def foo" })
      assert_includes res, "def foo"
      assert res.valid_encoding?
    end
  end

  def test_grep_buffer_content_with_invalid_bytes_does_not_raise
    Dir.mktmpdir do |temp_dir|
      buffer = Rubik::Buffer::Manager.new(root_dir: temp_dir)
      buffer.write("a.rb", "data\xFFmore\ndef goo\n".dup.force_encoding(Encoding::UTF_8))
      idx = Rubik::Context::Index.new(root_dir: temp_dir, native: "off")
      tool = Rubik::Tools::GrepSearchTool.new(buffer, idx, root_dir: temp_dir, config: NativeOffConfig.new)
      res = tool.execute({ "query" => "def goo" })
      assert_includes res, "def goo"
    end
  end

  def test_scanner_ignores_gitnexus
    assert_includes Rubik::Context::Scanner::DEFAULT_IGNORES, ".gitnexus/**"
    Dir.mktmpdir do |temp_dir|
      Dir.mkdir(File.join(temp_dir, ".gitnexus"))
      File.binwrite(File.join(temp_dir, ".gitnexus", "cache.bin"), "\x80\x81\x82invalid")
      idx = Rubik::Context::Index.new(root_dir: temp_dir, native: "off")
      files = idx.full_scan
      assert_empty(files.select { |k, _| k.start_with?(".gitnexus/") })
    end
  end

  def test_read_text_tags_utf8_and_scrubs_invalid
    Dir.mktmpdir do |temp_dir|
      path = File.join(temp_dir, "broken.rb")
      File.binwrite(path, "x = 1\ninvalid \xFF byte\ncafé")
      content = Rubik::Platform.read_text(path)
      assert content.valid_encoding?
      assert_equal Encoding::UTF_8, content.encoding
      assert_includes content, "café" # valid multibyte preserved
    end
  end

  def test_buffer_read_is_valid_utf8_and_hash_stable
    Dir.mktmpdir do |temp_dir|
      File.binwrite(File.join(temp_dir, "b.rb"), "d\xFFata\ndef run; end\n")
      buffer = Rubik::Buffer::Manager.new(root_dir: temp_dir)
      content1 = buffer.read("b.rb")
      assert content1.valid_encoding?
      assert_equal content1, buffer.read("b.rb")
      h1 = buffer.send(:disk_hash, "b.rb")
      assert_equal h1, buffer.send(:disk_hash, "b.rb")
      refute_nil h1
    end
  end
end
