# frozen_string_literal: true

require_relative "../test_helper"

class TestPlatformIoDrain < Minitest::Test
  def test_drains_chatty_child_so_it_never_blocks
    omit "ruby path contains spaces" if RbConfig.ruby.include?(" ")

    dir = Dir.mktmpdir
    marker = File.join(dir, "marker")
    rd, wr = IO.pipe
    child_code = "$stderr.sync = true; 4000.times { |i| $stderr.puts 'n' * 120 }; File.write(#{marker.inspect}, 'done')"
    pid = Process.spawn(RbConfig.ruby, "-e", child_code, out: File::NULL, err: wr)
    wr.close
    drain = Rubik::Platform::IoDrain.start(rd)

    # Without a drain the child blocks once the OS pipe buffer (~64KB)
    # fills and never reaches the marker write.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until File.exist?(marker) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end

    assert File.exist?(marker), "child must never block on a drained stderr pipe"
    drain.stop
    Process.wait(pid)
  ensure
    begin
      Process.kill("KILL", pid) if defined?(pid) && pid
      Process.wait(pid)
    rescue StandardError
      nil
    end
    [rd, wr].each { |io| io.close unless io.nil? || io.closed? }
    remove_temp_dir(dir)
  end

  def test_stop_terminates_thread_and_never_raises
    rd, wr = IO.pipe
    drain = Rubik::Platform::IoDrain.start(rd)

    assert_nil drain.stop
    assert_nil drain.instance_variable_get(:@thread)

    [rd, wr].each { |io| io.close unless io.closed? }
  end

  def test_on_line_observer_receives_lines
    rd, wr = IO.pipe
    lines = []
    drain = Rubik::Platform::IoDrain.start(rd, on_line: ->(l) { lines << l })

    wr.write("one\ntwo\n")
    wr.close
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until lines.size == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    drain.stop

    assert_equal %w[one two], lines.map(&:strip)
    rd.close unless rd.closed?
  end
end
