# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestKernelDmesg < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("dmesg_test")
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(
      config: Rubik::Config.new(root_dir: @temp_dir),
      buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir),
      output: @output
    )
    @dmesg = @shell.dmesg
  end

  def teardown
    @shell.stop
    FileUtils.remove_entry(@temp_dir)
  end

  def test_record_data_and_formatting
    rec = Rubik::Kernel::Record.new(
      seq: 42,
      uptime: 12.450123,
      subsystem: :subagent,
      level: :warn,
      facility_id: "subagent-1",
      message: "Reached step budget (88) and paused.",
      data: { budget: 88 }
    )

    assert_equal 42, rec.seq
    assert_in_delta 12.450123, rec.uptime, 0.000001
    assert_equal :subagent, rec.subsystem
    assert_equal :warn, rec.level
    assert_equal "subagent-1", rec.facility_id
    assert_equal "Reached step budget (88) and paused.", rec.message
    assert_equal({ budget: 88 }, rec.data)

    line = rec.format_line
    # Session review B1: payload data renders inline (bounded key=value) so
    # an event line carries its facts — the server that failed, the budget
    # that paused — instead of a bare event name.
    assert_equal "[  +12.450123] [subagent/subagent-1] WARN: Reached step budget (88) and paused. budget=88", line

    # Without facility_id
    rec_no_fac = Rubik::Kernel::Record.new(
      seq: 1,
      uptime: 0.123456,
      subsystem: :kernel,
      level: :info,
      facility_id: nil,
      message: "Boot complete.",
      data: {}
    )
    assert_equal "[   +0.123456] [kernel] INFO: Boot complete.", rec_no_fac.format_line

    # Color output
    colored = rec.format_line(color: true)
    assert_includes colored, "\e[33mWARN:"
    assert_includes colored, "\e[0m"
  end

  def test_severity_levels_and_normalization
    assert_equal 0, Rubik::Kernel::SEVERITY_LEVELS[:emerg]
    assert_equal 3, Rubik::Kernel::SEVERITY_LEVELS[:err]
    assert_equal 4, Rubik::Kernel::SEVERITY_LEVELS[:warn]
    assert_equal 7, Rubik::Kernel::SEVERITY_LEVELS[:debug]

    assert_equal :err, Rubik::Kernel.normalize_level("error")
    assert_equal :err, Rubik::Kernel.normalize_level(:err)
    assert_equal :warn, Rubik::Kernel.normalize_level("warning")
    assert_equal :warn, Rubik::Kernel.normalize_level("WARN")
    assert_equal :info, Rubik::Kernel.normalize_level("unknown_level")
  end

  def test_capacity_overflow_circular_overwriting_and_seq_continuity
    ring = Rubik::Kernel::Dmesg.new(capacity: 3)
    assert_equal 3, ring.capacity
    assert_predicate ring, :empty?
    assert_equal 0, ring.size

    r1 = ring.log(:init, :info, "msg 1")
    r2 = ring.log(:subagent, :warn, "msg 2")
    r3 = ring.log(:net, :err, "msg 3")

    assert_equal 1, r1.seq
    assert_equal 2, r2.seq
    assert_equal 3, r3.seq
    assert_equal 3, ring.size

    # 4th message overwrites r1 (msg 1)
    r4 = ring.log(:kernel, :info, "msg 4")
    assert_equal 4, r4.seq
    assert_equal 3, ring.size

    # 5th message overwrites r2 (msg 2)
    r5 = ring.log(:buffer, :debug, "msg 5")
    assert_equal 5, r5.seq
    assert_equal 3, ring.size

    # Records in chronological order are now r3, r4, r5
    records = ring.to_a
    assert_equal 3, records.size
    assert_equal [3, 4, 5], records.map(&:seq)
    assert_equal ["msg 3", "msg 4", "msg 5"], records.map(&:message)
  end

  def test_multi_threaded_thread_safety
    ring = Rubik::Kernel::Dmesg.new(capacity: 500)
    threads = []
    read_threads = []
    running = true

    # 5 concurrent reader threads
    5.times do
      read_threads << Thread.new do
        while running
          ring.tail(20)
          Thread.pass
        end
      end
    end

    # 10 concurrent writer threads, 100 entries each
    10.times do |t_idx|
      threads << Thread.new do
        100.times do |i|
          ring.log(:subagent, :info, "thread #{t_idx} entry #{i}", facility_id: "agent-#{t_idx}")
        end
      end
    end

    threads.each(&:join)
    running = false
    read_threads.each(&:join)

    assert_equal 500, ring.size
    assert_equal 1000, ring.seq_counter
    records = ring.to_a
    assert_equal 500, records.size
    # Sequence numbers should be strictly increasing in the ring snapshot
    assert_equal records.map(&:seq).sort, records.map(&:seq)
  end

  def test_tail_filtering_by_subsystem_level_and_since_seq
    ring = Rubik::Kernel::Dmesg.new(capacity: 50)
    ring.log(:init, :info, "Init started")
    ring.log(:subagent, :warn, "Subagent budget warning", facility_id: "agent-1")
    ring.log(:subagent, :err, "Subagent failed", facility_id: "agent-1")
    ring.log(:net, :err, "HTTP timeout")
    ring.log(:llm, :info, "Prompt streamed")
    ring.log(:buffer, :debug, "Buffer write")

    # Filter by subsystem
    sub_recs = ring.tail(10, subsystem: :subagent)
    assert_equal 2, sub_recs.size
    assert(sub_recs.all? { |r| r.subsystem == :subagent })

    # Filter by multiple subsystems (string with commas)
    multi_subs = ring.tail(10, subsystem: "subagent,net")
    assert_equal 3, multi_subs.size
    assert_equal [:subagent, :subagent, :net], multi_subs.map(&:subsystem)

    # Filter by level (single level)
    errs = ring.tail(10, level: :err)
    assert_equal 2, errs.size
    assert(errs.all? { |r| r.level == :err })

    # Filter by multiple levels
    warn_errs = ring.tail(10, level: "warn,err")
    assert_equal 3, warn_errs.size
    assert_equal [:warn, :err, :err], warn_errs.map(&:level)

    # Filter by numeric level threshold (<= 3: emerg, alert, crit, err)
    threshold_recs = ring.tail(10, level: 3)
    assert_equal 2, threshold_recs.size
    assert(threshold_recs.all? { |r| r.level == :err })

    # Filter by since_seq (seq > 3)
    since_recs = ring.tail(10, since_seq: 3)
    assert_equal 3, since_recs.size
    assert_equal [4, 5, 6], since_recs.map(&:seq)

    # Filter combined
    combined = ring.tail(10, subsystem: :subagent, level: :err, since_seq: 2)
    assert_equal 1, combined.size
    assert_equal 3, combined.first.seq
    assert_equal "Subagent failed", combined.first.message

    # Limit constraint
    assert_equal 2, ring.tail(2).size
    assert_equal [5, 6], ring.tail(2).map(&:seq)
  end

  def test_clear_resets_buffer
    ring = Rubik::Kernel::Dmesg.new(capacity: 10)
    ring.log(:kernel, :info, "Message 1")
    ring.log(:kernel, :info, "Message 2")
    assert_equal 2, ring.size

    ring.clear!
    assert_equal 0, ring.size
    assert_predicate ring, :empty?
    assert_empty ring.tail
  end

  def test_formatted_output
    ring = Rubik::Kernel::Dmesg.new(capacity: 10)
    ring.log(:init, :info, "Boot complete.")
    ring.log(:subagent, :warn, "High latency", facility_id: "worker-1")

    formatted = ring.formatted
    assert_includes formatted, "[init] INFO: Boot complete."
    assert_includes formatted, "[subagent/worker-1] WARN: High latency"
    assert_equal 2, formatted.lines.size

    # Formatted with explicit records slice
    slice = ring.tail(1)
    assert_equal 1, ring.formatted(slice).lines.size
  end

  def test_repl_dmesg_command
    @output.reopen
    @dmesg.clear!

    # Empty buffer message
    @shell.execute_input("!dmesg")
    assert_includes @output.string, "Kernel dmesg log buffer is empty."

    # Populate entries
    @dmesg.log(:init, :info, "System starting")
    @dmesg.log(:subagent, :warn, "Approaching budget", facility_id: "agent-a")
    @dmesg.log(:net, :err, "Connection refused")

    @output.reopen
    @shell.execute_input("!dmesg")
    assert_includes @output.string, "[init] INFO: System starting"
    assert_includes @output.string, "[subagent/agent-a] WARN: Approaching budget"
    assert_includes @output.string, "[net] ERR: Connection refused"

    # With -l filter
    @output.reopen
    @shell.execute_input("!dmesg -l err")
    assert_includes @output.string, "[net] ERR: Connection refused"
    refute_includes @output.string, "Approaching budget"

    # With -s filter
    @output.reopen
    @shell.execute_input("!dmesg -s subagent")
    assert_includes @output.string, "[subagent/agent-a] WARN: Approaching budget"
    refute_includes @output.string, "Connection refused"

    # With -n limit
    @output.reopen
    @shell.execute_input("!dmesg -n 1")
    assert_includes @output.string, "[net] ERR: Connection refused"
    refute_includes @output.string, "System starting"

    # With --since
    @output.reopen
    @shell.execute_input("!dmesg --since 2")
    assert_includes @output.string, "[net] ERR: Connection refused"
    refute_includes @output.string, "System starting"

    # Clear command
    @output.reopen
    @shell.execute_input("!dmesg clear")
    assert_includes @output.string, "Kernel dmesg buffer cleared."
    assert_predicate @dmesg, :empty?
  end

  def test_builtin_dmesg_tool
    tool = @shell.tool_registry.get("dmesg")
    assert tool, "dmesg tool must be registered in default tool registry"
    assert_equal "dmesg", tool.name
    assert_equal :read, tool.risk

    schema = tool.params_schema
    assert_equal "object", schema[:type]
    props = schema[:properties]
    assert props[:limit]
    assert props[:level]
    assert props[:subsystem]
    assert props[:since_seq]

    @dmesg.clear!
    @dmesg.log(:subagent, :warn, "Step budget warning", facility_id: "sub-1")
    @dmesg.log(:kernel, :info, "GC triggered")

    # Tool execution without args returns all
    out = tool.execute({})
    assert_includes out, "[subagent/sub-1] WARN: Step budget warning"
    assert_includes out, "[kernel] INFO: GC triggered"

    # Tool execution with filters
    subagent_out = tool.execute("subsystem" => "subagent")
    assert_includes subagent_out, "Step budget warning"
    refute_includes subagent_out, "GC triggered"

    level_out = tool.execute("level" => "info")
    assert_includes level_out, "GC triggered"
    refute_includes level_out, "Step budget warning"
  end

  def test_composition_and_runtime_context_wiring
    ctx = @shell.runtime_manager.context
    assert_same @dmesg, ctx.get(:dmesg)
    assert_same @dmesg, ctx.require(:dmesg)

    # Injected parts override verification
    custom_dmesg = Rubik::Kernel::Dmesg.new(capacity: 100)
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir, dmesg: custom_dmesg)
    assert_same custom_dmesg, parts.dmesg
  end
end
