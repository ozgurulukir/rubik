# frozen_string_literal: true

require_relative "../test_helper"

class TestAutonomousDiagnosticAndRepair < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_repair_test")
    @config = Rubik::Config.new(root_dir: @temp_dir)
    @runtime_manager = Rubik::Runtime::Manager.new
    @adapter_registry = Rubik::Adapter::Registry.new
    @lsp_manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir, runtime_manager: @runtime_manager)
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir)

    @tool = Rubik::Tools::RepairRuntimeTool.new(
      runtime_manager: @runtime_manager,
      lsp_manager: @lsp_manager,
      adapter_registry: @adapter_registry,
      overlay_storage: @overlay_storage,
      config: @config,
      root_dir: @temp_dir
    )
  end

  def teardown
    @runtime_manager.context.dispose
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_invalid_command_flags_are_not_functionally_verified
    @runtime_manager.context.provide("command:ruby", "ruby -v")
    result = @tool.execute(target: "command", language_or_type: "ruby",
                           proposed_command: "ruby --rubik-invalid-option", auto_probe: false)

    assert_includes result, "Verification failed"
    assert_equal "ruby -v", @runtime_manager.context.require("command:ruby")
  end

  def test_persistence_failure_restores_adapter_service_and_config
    adapter = @adapter_registry.get("ruby")
    adapter.custom_test_cmd = "old runner"
    adapter.config = nil
    @config.set("test.runners.ruby", "old runner")
    @runtime_manager.context.provide("runner:ruby", "old service")
    baseline = @runtime_manager.context.disposable_count
    original_set = @config.method(:set)
    failing_set = lambda do |key, value, **options|
      result = original_set.call(key, value)
      options[:persist] ? { ok: false, error: "disk full" } : result
    end
    result = @config.stub(:set, failing_set) do
      @tool.execute(target: "test_runner", language_or_type: "ruby", proposed_command: "ruby -v")
    end
    assert_includes result, "Persistence failed"
    assert_equal "old runner", @config.fetch("test.runners.ruby")
    assert_equal "old runner", adapter.custom_test_cmd
    assert_nil adapter.config
    assert_equal "old service", @runtime_manager.context.require("runner:ruby")
    assert_equal baseline, @runtime_manager.context.disposable_count
  end

  def test_normal_cleanup_restores_adapter_but_retains_persisted_operator_config
    adapter = @adapter_registry.get("ruby")
    adapter.custom_test_cmd = "old runner"
    @config.set("test.runners.ruby", "old runner")
    result = @tool.execute(target: "test_runner", language_or_type: "ruby", proposed_command: "ruby -v")
    assert_includes result, "Successfully verified"
    @runtime_manager.context.dispose
    assert_equal "old runner", adapter.custom_test_cmd
    assert_equal "old runner", @config.fetch("test.runners.ruby")
    assert_includes File.read(File.join(@temp_dir, ".rubik", "config.yml")), "ruby -v"
    refute @runtime_manager.context.has?("runner:ruby")
  end

  def test_lsp_probe_rejects_working_binary_without_handshake
    result = @tool.execute(target: "lsp", language_or_type: "ruby", proposed_command: "ruby -v")
    assert_includes result, "Verification failed"
    refute @runtime_manager.context.has?("lsp:ruby")
    assert_empty @lsp_manager.clients
  end

  def test_probe_timeout_reaps_process_and_child_context
    script = File.join(@temp_dir, "slow.rb")
    pid_file = File.join(@temp_dir, "probe.pid")
    File.write(script, "File.write(#{pid_file.inspect}, Process.pid); sleep 30")
    baseline = @runtime_manager.context.disposable_count
    result = @tool.execute(target: "command", language_or_type: "slow",
                           proposed_command: "ruby #{script}", probe_args: ["--help"])
    assert_includes result, "TIMEOUT"
    assert_equal baseline, @runtime_manager.context.disposable_count
    assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(pid_file))) }
    refute @runtime_manager.context.has?("command:slow")
  end

  def test_repeated_repairs_keep_one_scope_and_restore_original_adapter
    adapter = @adapter_registry.get("ruby")
    adapter.custom_test_cmd = "original"
    3.times do
      result = @tool.execute(target: "test_runner", language_or_type: "ruby", proposed_command: "ruby -v")
      assert_includes result, "Successfully verified"
      @repair_scope_count ||= @runtime_manager.context.disposable_count
      assert_equal @repair_scope_count, @runtime_manager.context.disposable_count
    end
    @runtime_manager.context.dispose
    assert_equal "original", adapter.custom_test_cmd
    assert_empty @runtime_manager.context.services
  end

  def test_successful_lsp_probe_stops_only_the_probe_client
    probe = Minitest::Mock.new
    probe.expect(:start, { "capabilities" => {} })
    probe.expect(:alive?, true)
    probe.expect(:stop, nil)
    active = Object.new
    active.define_singleton_method(:stop) {}
    start = lambda { |_lang|
      @lsp_manager.clients["ruby"] = active
      { ok: true }
    }
    result = Rubik::LSP::Client.stub(:new, probe) do
      @lsp_manager.stub(:start_client, start) do
        @tool.execute(target: "lsp", language_or_type: "ruby", proposed_command: "ruby -v")
      end
    end
    assert_includes result, "Successfully verified"
    assert_same active, @runtime_manager.context.require("lsp:ruby")
    assert_same active, @lsp_manager.clients["ruby"]
    probe.verify
  end

  def write_lsp_server
    script = File.join(@temp_dir, "server.rb")
    pids = File.join(@temp_dir, "server.pids")
    File.write(script, <<~RUBY)
      require "json"
      File.open(#{pids.inspect}, "a") { |file| file.puts(Process.pid) }
      loop do
        header = $stdin.gets or break
        size = header.split(":").last.to_i
        $stdin.gets
        message = JSON.parse($stdin.read(size))
        break if message["method"] == "exit"
        next unless message["id"]
        body = JSON.dump(jsonrpc: "2.0", id: message["id"], result: { capabilities: {} })
        $stdout.write("Content-Length: " + body.bytesize.to_s + "\r\n\r\n" + body)
        $stdout.flush
      end
    RUBY
    [script, pids]
  end

  def test_real_lsp_handshake_uses_separate_probe_and_live_processes
    script, pids = write_lsp_server
    result = @tool.execute(target: "lsp", language_or_type: "ruby", proposed_command: "ruby #{script}")
    assert_includes result, "Successfully verified"
    probe_pid, live_pid = File.readlines(pids).map(&:to_i)
    refute_equal probe_pid, live_pid
    assert_raises(Errno::ESRCH) { Process.kill(0, probe_pid) }
    assert @lsp_manager.clients["ruby"].alive?
    @runtime_manager.context.dispose
    assert_raises(Errno::ESRCH) { Process.kill(0, live_pid) }
  end

  def test_structured_lsp_command_is_verified_started_and_persisted
    script, pids = write_lsp_server
    command = { "executable" => RbConfig.ruby, "args" => [script, "argument with spaces", "literal; metachar"] }

    result = @tool.execute(
      target: "lsp", language_or_type: "ruby", proposed_command: command, auto_probe: false
    )

    assert_includes result, "Successfully verified"
    assert_equal command, @config.fetch("lsp.servers.ruby")
    assert_equal command, Rubik::Config.new(root_dir: @temp_dir).fetch("lsp.servers.ruby")
    assert @lsp_manager.clients["ruby"].alive?
    @runtime_manager.context.dispose
    File.readlines(pids).map(&:to_i).each do |pid|
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_lsp_persistence_failure_restores_a_working_previous_client
    script, pids = write_lsp_server
    command = "ruby #{script}"
    @config.set("lsp.servers.ruby", command)
    assert @lsp_manager.start_client("ruby")[:ok]
    old_client = @lsp_manager.clients["ruby"]
    original_set = @config.method(:set)
    failing_set = lambda do |key, value, **options|
      result = original_set.call(key, value)
      options[:persist] ? { ok: false, error: "disk full" } : result
    end
    result = @config.stub(:set, failing_set) do
      @tool.execute(target: "lsp", language_or_type: "ruby", proposed_command: command)
    end
    assert_includes result, "Persistence failed"
    assert_includes result, "previous session state restored"
    assert_equal command, @config.fetch("lsp.servers.ruby")
    refute old_client.alive?
    assert @lsp_manager.clients["ruby"].alive?
    assert_same @lsp_manager.clients["ruby"], @runtime_manager.context.require("lsp:ruby")
    @runtime_manager.context.dispose
    File.readlines(pids).map(&:to_i).each do |pid|
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_failed_handshake_cleans_probe_without_promotion
    probe = Minitest::Mock.new
    probe.expect(:start, false)
    probe.expect(:stop, nil)
    result = Rubik::LSP::Client.stub(:new, probe) do
      @tool.execute(target: "lsp", language_or_type: "ruby", proposed_command: "ruby -v")
    end
    assert_includes result, "handshake rejected"
    assert_empty @lsp_manager.clients
    refute @runtime_manager.context.has?("lsp:ruby")
    probe.verify
  end

  def test_promotion_exception_restores_existing_adapter
    adapter = @adapter_registry.get("ruby")
    adapter.custom_test_cmd = "original"
    original_setter = adapter.method(:custom_test_cmd=)
    setter = ->(value) { value == "ruby -v" ? raise("adapter activation failed") : original_setter.call(value) }
    result = adapter.stub(:custom_test_cmd=, setter) do
      @tool.execute(target: "test_runner", language_or_type: "ruby", proposed_command: "ruby -v")
    end
    assert_includes result, "Promotion failed"
    assert_equal "original", adapter.custom_test_cmd
    assert_nil adapter.config
    refute @runtime_manager.context.has?("runner:ruby")
    refute File.exist?(File.join(@temp_dir, ".rubik", "config.yml"))
  end

  def test_diagnostic_engine_classifications
    # Missing binary
    d1 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "unknown_lsp_server --stdio",
      exit_code: 127,
      stderr: "sh: 1: unknown_lsp_server: not found"
    )
    assert_equal :missing_binary, d1.category
    assert_includes d1.suggestion, "not found"
    assert_includes d1.format_for_llm, "MISSING_BINARY"

    # Timeout
    d2 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "slow_test_runner",
      exit_code: 124,
      stderr: "Execution timed out after 15 seconds"
    )
    assert_equal :timeout, d2.category
    assert_includes d2.suggestion, "timeout"

    # Missing flags
    d3 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "typeprof",
      exit_code: 1,
      stderr: "typeprof: unrecognized option '--invalid'\nrequires stdio"
    )
    assert_equal :missing_flag_or_option, d3.category

    # Dependency missing
    d4 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "bundle exec rspec",
      exit_code: 1,
      stderr: "Could not find gem 'rspec' in locally installed gems. Run `bundle install`."
    )
    assert_equal :dependency_missing, d4.category

    # Syntax error
    d5 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "ruby -c bad.rb",
      exit_code: 1,
      stderr: "bad.rb:1: syntax error, unexpected end-of-input"
    )
    assert_equal :syntax_or_compile_error, d5.category

    # Test failure
    d6 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "rake test",
      exit_code: 1,
      stdout: "10 runs, 20 assertions, 2 failures, 0 errors, 0 skips"
    )
    assert_equal :test_failure, d6.category
  end

  def test_repair_service_preflight_failure_rollback
    res = @tool.execute(
      "target" => "test_runner",
      "language_or_type" => "ruby",
      "proposed_command" => "non_existent_runner_binary_xyz_123",
      "auto_probe" => false
    )

    assert_includes res, "Verification failed"
    assert_includes res, "MISSING_BINARY"
    # Ensure context was not polluted
    refute @runtime_manager.context.has?("runner:ruby")
  end

  def test_repair_test_runner_success_and_hot_swap
    res = @tool.execute(
      "target" => "test_runner",
      "language_or_type" => "ruby",
      "proposed_command" => "ruby -v",
      "auto_probe" => false
    )

    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("runner:ruby")
    assert_equal "ruby -v", @adapter_registry.get("ruby").custom_test_cmd
  end

  def test_repair_linter_success
    res = @tool.execute(
      "target" => "linter",
      "language_or_type" => "ruby",
      "proposed_command" => "ruby -c",
      "auto_probe" => false
    )

    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("linter:ruby")
    assert_equal "ruby -c", @adapter_registry.get("ruby").custom_format_cmd
  end

  def test_repair_with_auto_probe
    File.write(File.join(@temp_dir, "Gemfile"), "source \"https://rubygems.org\"\ngem \"rake\"\n")
    res = @tool.execute(
      "target" => "test_runner",
      "language_or_type" => "ruby",
      "auto_probe" => true
    )

    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("runner:ruby")
  end

  def test_diagnostic_engine_permission_denied_and_process_result_analysis
    res_mock = {
      ok: false,
      cmd: "/bin/restricted_script.sh",
      exit_code: 126,
      output: "bash: /bin/restricted_script.sh: Permission denied",
      duration: 0.05
    }
    failure = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res_mock)
    assert_equal :permission_denied, failure.category
    assert_includes failure.suggestion, "Permission denied"
    assert_equal 126, failure.exit_code
    assert_in_delta 0.05, failure.duration, 0.001
  end

  def test_diagnostic_engine_success_analysis
    res_mock = {
      ok: true,
      cmd: "echo 'hello'",
      exit_code: 0,
      stdout: "hello\n",
      duration: 0.01
    }
    diag = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res_mock)
    assert_equal :success, diag.category
    assert_includes diag.suggestion, "successfully"
  end

  def test_repair_lsp_start_failure_rolls_back_configuration
    @config.set("lsp.servers.ruby", "solargraph stdio")
    start_stub = ->(_lang) { { ok: false, error: "stub handshake failure" } }
    res = nil
    @tool.stub(:verify_binary, [true, nil]) do
      @lsp_manager.stub(:start_client, start_stub) do
        res = @tool.execute(
          "target" => "lsp",
          "language_or_type" => "ruby",
          "proposed_command" => "ruby -v", # valid binary, but not an LSP server
          "auto_probe" => false
        )
      end
    end

    assert_includes res, "Failed to start LSP server"
    assert_includes res, "previous session state restored"
    # In-memory rollback to the previous configured command; no service promoted
    assert_equal "solargraph stdio", @config.fetch("lsp.servers.ruby")
    refute @runtime_manager.context.has?("lsp:ruby")
    # Atomicity on disk: the failed promotion must never persist the broken command
    project_cfg = File.join(@temp_dir, ".rubik", "config.yml")
    refute File.exist?(project_cfg), "Failed promotion must not write the broken command to project config"
  end

  def test_repair_lsp_rollback_restart_failure_unprovides_service_and_reports_incomplete
    old_client = Object.new
    old_client.define_singleton_method(:stop) {}
    old_client.define_singleton_method(:alive?) { false }
    @lsp_manager.clients["ruby"] = old_client
    @runtime_manager.context.provide("lsp:ruby", old_client)
    @config.set("lsp.servers.ruby", "solargraph stdio")

    start_stub = ->(_lang) { { ok: false, error: "crashed during start" } }

    res = nil
    @tool.stub(:verify_binary, [true, nil]) do
      @lsp_manager.stub(:start_client, start_stub) do
        res = @tool.execute(
          "target" => "lsp",
          "language_or_type" => "ruby",
          "proposed_command" => "ruby -v",
          "auto_probe" => false
        )
      end
    end

    assert_includes res, "rollback incomplete"
    refute @runtime_manager.context.has?("lsp:ruby")
  end

  def test_repair_lsp_success_persists_only_after_verified_start
    client = Object.new
    client.define_singleton_method(:stop) {}
    start_stub = lambda { |_lang|
      @lsp_manager.clients["ruby"] = client
      { ok: true, message: "stubbed start" }
    }
    res = nil
    @tool.stub(:verify_binary, [true, nil]) do
      @lsp_manager.stub(:start_client, start_stub) do
        res = @tool.execute(
          "target" => "lsp",
          "language_or_type" => "ruby",
          "proposed_command" => "ruby -v", # real binary passes preflight; start is stubbed
          "auto_probe" => false
        )
      end
    end

    assert_includes res, "Successfully verified and promoted"
    # Config is set (and persisted to the temp project dir) only on success
    assert_equal "ruby -v", @config.fetch("lsp.servers.ruby")
    assert @runtime_manager.context.has?("lsp:ruby")
    project_cfg = File.join(@temp_dir, ".rubik", "config.yml")
    assert File.exist?(project_cfg), "Verified promotion must persist to project config"
    assert_includes File.read(project_cfg), "ruby -v"
  end

  def test_repair_command_target
    res = @tool.execute(
      "target" => "command",
      "language_or_type" => "echo",
      "proposed_command" => "echo 'ok'",
      "auto_probe" => false
    )
    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("command:echo")
  end

  def test_repair_invalid_target_type
    res = @tool.execute(
      "target" => "unsupported_target_type",
      "language_or_type" => "ruby",
      "proposed_command" => "ruby -v"
    )
    assert_includes res, "Verification failed"
    assert_includes res, "Unknown target component type"
  end
end
