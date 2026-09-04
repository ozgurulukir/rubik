# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/client"

class TestSSEParserAndStreamResilience < Minitest::Test
  def setup
    @parser = Rubik::LLM::SSEParser.new
  end

  def test_crlf_crlf_separation
    stream = "data: {\"chunk\": 1}\r\n\r\ndata: {\"chunk\": 2}\r\n\r\n"
    events = @parser.feed(stream)
    assert_equal 2, events.size
    assert_equal "{\"chunk\": 1}", events[0][:data]
    assert_equal "{\"chunk\": 2}", events[1][:data]
  end

  def test_lf_lf_separation
    stream = "data: alpha\n\ndata: beta\n\n"
    events = @parser.feed(stream)
    assert_equal 2, events.size
    assert_equal "alpha", events[0][:data]
    assert_equal "beta", events[1][:data]
  end

  def test_mixed_line_endings_separation
    stream = "data: one\r\n\ndata: two\n\r\ndata: three\r\rdata: four\r\n\r\n"
    events = @parser.feed(stream)
    assert_equal 4, events.size
    assert_equal "one", events[0][:data]
    assert_equal "two", events[1][:data]
    assert_equal "three", events[2][:data]
    assert_equal "four", events[3][:data]
  end

  def test_chunk_boundary_split_on_cr
    # Chunk 1 ends right on \r of \r\n\r\n
    c1 = "data: msg1\r\n\r"
    events1 = @parser.feed(c1)
    assert_empty events1 # Should not prematurely split

    # Chunk 2 delivers \n\ndata: msg2\r\n\r\n
    c2 = "\ndata: msg2\r\n\r\n"
    events2 = @parser.feed(c2)
    assert_equal 2, events2.size
    assert_equal "msg1", events2[0][:data]
    assert_equal "msg2", events2[1][:data]
  end

  def test_chunk_boundary_split_mid_double_cr
    c1 = "data: chunkA\r"
    events1 = @parser.feed(c1)
    assert_empty events1

    c2 = "\rdata: chunkB\n\n"
    events2 = @parser.feed(c2)
    assert_equal 2, events2.size
    assert_equal "chunkA", events2[0][:data]
    assert_equal "chunkB", events2[1][:data]
  end

  def test_multi_line_data_fields
    stream = "data: line 1\r\ndata: line 2\r\ndata: line 3\r\n\r\n"
    events = @parser.feed(stream)
    assert_equal 1, events.size
    assert_equal "line 1\nline 2\nline 3", events[0][:data]
  end

  def test_comments_filtered_and_pure_comment_blocks_skipped
    # Comment mixed with data
    stream = ": keepalive ping\r\ndata: real data\r\n\r\n"
    events = @parser.feed(stream)
    assert_equal 1, events.size
    assert_equal "real data", events[0][:data]

    # Block with ONLY comments and blank lines
    ping_stream = ": ping\r\n: second comment\r\n\r\n"
    events_ping = @parser.feed(ping_stream)
    assert_empty events_ping
  end

  def test_empty_blocks_produce_no_events
    events = @parser.feed("\r\n\r\n\n\n\r\r")
    assert_empty events
  end

  def test_flush_with_complete_and_trailing_events
    feed_events = @parser.feed("data: first\r\n\r\ndata: second")
    assert_equal 1, feed_events.size
    assert_equal "first", feed_events[0][:data]

    flush_events = @parser.flush
    assert_equal 1, flush_events.size
    assert_equal "second", flush_events[0][:data]
  end

  def test_flush_on_empty_buffer_returns_empty_array
    events = @parser.flush
    assert_equal [], events
  end

  def test_flush_on_pure_comment_trailing_buffer_returns_empty_array
    @parser.feed(": trailing comment")
    events = @parser.flush
    assert_equal [], events
  end
end
