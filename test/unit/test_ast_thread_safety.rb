# frozen_string_literal: true

require_relative "../test_helper"

class TestASTThreadSafety < Minitest::Test
  def test_concurrent_lazy_body_loading_is_thread_safe
    call_count = 0
    call_count_mutex = Mutex.new

    loader = lambda do
      sleep 0.01 # Small delay to increase chance of race condition
      call_count_mutex.synchronize { call_count += 1 }
      "def thread_safe_method\n  42\nend\n"
    end

    sym = Rubik::AST::Symbol.new(
      name: "thread_safe_method",
      kind: :function,
      file: "test.rb",
      line_start: 1,
      line_end: 3,
      body_loader: loader
    )

    threads = 10.times.map do
      Thread.new do
        sym.body
      end
    end

    results = threads.map(&:value)

    assert_equal 1, call_count, "Lazy body loader must only be invoked exactly once across threads"
    results.each do |res|
      assert_equal "def thread_safe_method\n  42\nend\n", res
    end
  end

  def test_symbol_to_h_thread_safety
    sym = Rubik::AST::Symbol.new(
      name: "my_func",
      kind: :method,
      file: "app.rb",
      line_start: 10,
      line_end: 15,
      body_loader: -> { "puts :ok" }
    )

    threads = 5.times.map do
      Thread.new do
        sym.to_h
      end
    end

    results = threads.map(&:value)
    results.each do |h|
      assert_equal "my_func", h[:name]
      assert_equal "puts :ok", h[:body]
    end
  end
end
