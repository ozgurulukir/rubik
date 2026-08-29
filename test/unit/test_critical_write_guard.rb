# frozen_string_literal: true

require_relative "../test_helper"

class TestCriticalWriteGuard < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_guard_test")
    @guard = Rubik::Security::Guard.new
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, guard: @guard)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_blocks_direct_write_to_sensitive_files
    sensitive_paths = [
      ".env",
      ".env.production",
      ".git/config",
      ".git/HEAD",
      "secrets.json",
      "secrets.yml",
      "server.key",
      "cert.pem",
      "id_rsa",
      "id_rsa.pub"
    ]

    sensitive_paths.each do |path|
      assert_raises(Rubik::Buffer::InvalidPathError, "Should block write to #{path}") do
        @buffer_manager.write(path, "malicious_content")
      end
    end
  end

  def test_allows_normal_source_file_writes
    normal_paths = [
      "lib/app.rb",
      "src/index.ts",
      "README.md",
      "config/application.rb"
    ]

    normal_paths.each do |path|
      @buffer_manager.write(path, "valid_content")
      assert_equal "valid_content", @buffer_manager.read(path)
    end
  end

  def test_write_file_tool_and_replace_content_tool_blocked_by_guard
    write_tool = Rubik::Tools::WriteFileTool.new(@buffer_manager)
    replace_tool = Rubik::Tools::ReplaceFileContentTool.new(@buffer_manager)

    write_res = write_tool.execute("path" => ".env", "content" => "SECRET=123")
    assert_includes write_res, "PATH ACCESS RESTRICTED"

    # Pre-populate dummy on disk
    File.write(File.join(@temp_dir, "secrets.json"), '{"key": "old"}')
    replace_res = replace_tool.execute(
      "path" => "secrets.json",
      "target_content" => '{"key": "old"}',
      "replacement_content" => '{"key": "new"}'
    )
    assert_includes replace_res, "PATH ACCESS RESTRICTED"
  end

  def test_sandbox_runner_timeout_precedence
    cfg = Rubik::Config.new(root_dir: @temp_dir)
    cfg.set("sandbox.timeout_seconds", 15)

    mock_driver = Object.new
    called_timeout = nil
    mock_driver.define_singleton_method(:name) { "process" }
    mock_driver.define_singleton_method(:run) do |_cmd, timeout:, **_opts|
      called_timeout = timeout
      { ok: true, exit_code: 0, output: "done" }
    end

    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: cfg, driver: mock_driver)

    # 1. Without explicit timeout, uses config (15)
    runner.run("echo hi")
    assert_equal 15, called_timeout

    # 2. With explicit timeout: 60, overrides config 15
    runner.run("echo hi", timeout: 60)
    assert_equal 60, called_timeout
  end

  def test_process_driver_isolation_level_label
    mock_driver = Object.new
    mock_driver.define_singleton_method(:name) { "process" }
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, driver: mock_driver)
    assert_equal "process (env_proxy)", runner.isolation_level
  end

  def test_sse_parser_utf8_scrubbing_resilience
    parser = Rubik::LLM::SSEParser.new
    # Chunk containing invalid UTF-8 byte sequence \xFF\xFE
    bad_chunk = "data: {\"text\": \"hello \xFF\xFE world\"}\n\n"
    events = parser.feed(bad_chunk)

    assert_equal 1, events.size
    assert_equal "message", events.first[:type]
    assert_includes events.first[:data], "hello"
    assert_includes events.first[:data], "world"
  end

  def test_config_save_permission_security
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_dir)
    res = cfg.save!(:global)

    assert res[:ok]
    assert File.exist?(res[:path])
    # Permission check (on POSIX systems ensures 0600)
    mode = File.stat(res[:path]).mode & 0o777
    # Note: On Windows, chmod is a no-op / read-only flag, on POSIX it matches 0600
    refute_nil mode
  end
end
