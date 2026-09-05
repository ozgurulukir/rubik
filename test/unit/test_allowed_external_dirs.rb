# frozen_string_literal: true

require_relative "../test_helper"

class TestAllowedExternalDirs < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_primary_ws")
    @temp_home = Dir.mktmpdir("rubik_home")
    @allowed_dir1 = Dir.mktmpdir("rubik_allowed_scratch")
    @allowed_dir2 = Dir.mktmpdir("rubik_allowed_data")
    @allowed_dir3 = Dir.mktmpdir("rubik_allowed_tmp")
    @unauthorized_dir = Dir.mktmpdir("rubik_unauthorized_dir")

    # Primary files
    FileUtils.mkdir_p(File.join(@temp_root, "lib"))
    File.write(File.join(@temp_root, "lib", "app.rb"), "class App\n  def run\n    puts 'app running'\n  end\nend\n")

    # Files inside allowed external dirs
    File.write(File.join(@allowed_dir1, "temp_scratch.rb"), "class TempScratch\n  def scratch_method\n    42\n  end\nend\n")
    File.write(File.join(@allowed_dir2, "dataset.csv"), "id,name,value\n1,alpha,100\n")

    # Files inside unauthorized dir
    File.write(File.join(@unauthorized_dir, "secret_key.pem"), "-----BEGIN PRIVATE KEY-----")
  end

  def teardown
    begin
      FileUtils.remove_entry(@temp_root)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@temp_home)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@allowed_dir1)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@allowed_dir2)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@allowed_dir3)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@unauthorized_dir)
    rescue
      nil
    end
  end

  def test_config_schema_contains_allowed_external_dirs
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal [], cfg.fetch("workspace.allowed_external_dirs")
  end

  def test_buffer_reads_and_writes_in_allowed_external_dir
    manager = Rubik::Buffer::Manager.new(
      root_dir: @temp_root,
      allowed_external_dirs: [@allowed_dir1]
    )

    scratch_file = File.join(@allowed_dir1, "temp_scratch.rb")
    content = manager.read(scratch_file)
    assert_includes content, "class TempScratch"

    # Write modified content
    new_code = "class TempScratch\n  def scratch_method\n    999\n  end\nend\n"
    manager.write(scratch_file, new_code)
    assert manager.dirty?
    assert_equal new_code, manager.read(scratch_file)

    # Disk remains unchanged until apply!
    assert_includes File.read(scratch_file), "42"

    # Apply buffer to disk
    applied = manager.apply!
    assert_includes applied, scratch_file
    refute manager.dirty?
    assert_includes File.read(scratch_file), "999"
  end

  def test_buffer_blocks_unauthorized_external_dirs
    manager = Rubik::Buffer::Manager.new(
      root_dir: @temp_root,
      allowed_external_dirs: [@allowed_dir1]
    )

    unauthorized_file = File.join(@unauthorized_dir, "secret_key.pem")

    err_read = assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.read(unauthorized_file)
    end
    assert_includes err_read.message, "Path traversal attempt blocked"

    err_write = assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.write(unauthorized_file, "corrupted")
    end
    assert_includes err_write.message, "Path traversal attempt blocked"
  end

  def test_buffer_read_only_allowed_external_dir
    manager = Rubik::Buffer::Manager.new(
      root_dir: @temp_root,
      allowed_external_dirs: []
    )

    manager.add_allowed_dir(@allowed_dir2, rw: false)

    dataset_file = File.join(@allowed_dir2, "dataset.csv")
    assert_equal "id,name,value\n1,alpha,100\n", manager.read(dataset_file)

    err = assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.write(dataset_file, "id,name,value\n2,beta,200\n")
    end
    assert_includes err.message, "Write blocked on external allowed directory"
  end

  def test_zero_ast_and_zero_scanner_isolation
    # Initialize index and scanner with primary workspace
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_root)
    scanned_files = scanner.scan

    # Scanner only sees primary root
    assert_includes scanned_files.keys, "lib/app.rb"
    refute(scanned_files.keys.any? { |k| k.include?("temp_scratch.rb") })
    refute(scanned_files.keys.any? { |k| k.include?("dataset.csv") })

    # Index only sees primary root
    index = Rubik::Context::Index.new(root_dir: @temp_root)
    index_files = index.full_scan
    assert_includes index_files.keys, "lib/app.rb"
    refute(index_files.keys.any? { |k| k.include?("temp_scratch.rb") })

    # AST graph only has symbols from scanned files
    ast = Rubik::AST::Graph.new
    ast.index_file(File.join(@temp_root, "lib", "app.rb"))

    assert ast.symbols.key?("App")
    refute ast.symbols.key?("TempScratch")
    refute ast.symbols.key?("scratch_method")
  end

  def test_sandbox_runner_allowed_and_blocked_chdir
    runner = Rubik::Sandbox::Runner.new(
      root_dir: @temp_root,
      allowed_external_dirs: [@allowed_dir1]
    )

    # Allowed paths include root and allowed_dir1
    assert_includes runner.allowed_paths, @temp_root
    assert_includes runner.allowed_paths, @allowed_dir1
    refute_includes runner.allowed_paths, @unauthorized_dir

    test_cmd = "ruby -e \"puts Dir.pwd\""

    # Running in root succeeds
    res_root = runner.run(test_cmd, timeout: 5, chdir: @temp_root)
    assert res_root[:ok]

    # Running in allowed_dir1 succeeds
    res_allowed = runner.run(test_cmd, timeout: 5, chdir: @allowed_dir1)
    assert res_allowed[:ok]
    assert_includes Rubik::Platform.normalize_path(res_allowed[:stdout]), Rubik::Platform.normalize_path(@allowed_dir1)

    # Running in unauthorized dir is blocked by verify_chdir_safety!
    assert_raises(Rubik::Security::BlockedWriteError) do
      runner.run(test_cmd, timeout: 5, chdir: @unauthorized_dir)
    end
  end

  def test_sandbox_runner_dynamic_add_and_remove_allowed_dir
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_root)
    test_cmd = "ruby -e \"puts Dir.pwd\""

    # Initially unauthorized_dir is blocked
    assert_raises(Rubik::Security::BlockedWriteError) do
      runner.run(test_cmd, timeout: 5, chdir: @unauthorized_dir)
    end

    # Dynamically allow dir
    runner.add_allowed_dir(@unauthorized_dir)
    assert_includes runner.allowed_paths, @unauthorized_dir
    res = runner.run(test_cmd, timeout: 5, chdir: @unauthorized_dir)
    assert res[:ok]

    # Dynamically remove allowed dir
    runner.remove_allowed_dir(@unauthorized_dir)
    refute_includes runner.allowed_paths, @unauthorized_dir
    assert_raises(Rubik::Security::BlockedWriteError) do
      runner.run(test_cmd, timeout: 5, chdir: @unauthorized_dir)
    end
  end

  def test_repl_allow_command_workflow
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    # 1. Initial list is empty
    shell.execute_input("!allow list")
    assert_includes out.string, "=== Allowed External Directories (Zero-AST / Zero-Scanner) ==="
    assert_includes out.string, "(No allowed external directories configured)"

    # 2. Add allowed directory
    out.reopen
    shell.execute_input("!allow #{@allowed_dir1} --project")
    assert_includes out.string, "[Rubik::Allow] Added allowed external directory: #{@allowed_dir1} (Mode: Read-Write)"
    assert_includes out.string, "[Project level (.rubik/config.yml)]"

    # Verify buffer manager and sandbox runner received it
    assert_includes shell.buffer_manager.allowed_external_dirs, @allowed_dir1
    assert_includes shell.sandbox_runner.allowed_paths, @allowed_dir1

    # Verify context_index did NOT scan it (Zero-AST guarantee)
    refute_includes shell.context_index.additional_roots, @allowed_dir1

    # 3. Add read-only directory
    out.reopen
    shell.execute_input("!allow add #{@allowed_dir2} --ro --project")
    assert_includes out.string, "[Rubik::Allow] Added allowed external directory: #{@allowed_dir2} (Mode: Read-Only)"
    refute_includes shell.buffer_manager.rw_allowed_dirs, @allowed_dir2

    # 4. Check list output
    out.reopen
    shell.execute_input("!allow list")
    assert_includes out.string, "ALLOWED 1] #{@allowed_dir1} (Read-Write)"
    assert_includes out.string, "ALLOWED 2] #{@allowed_dir2} (Read-Only)"

    # 5. Remove allowed directory
    out.reopen
    shell.execute_input("!allow remove #{@allowed_dir1} --project")
    assert_includes out.string, "[Rubik::Allow] Removed allowed external directory: #{@allowed_dir1}"
    refute_includes shell.buffer_manager.allowed_external_dirs, @allowed_dir1
    refute_includes shell.sandbox_runner.allowed_external_dirs, @allowed_dir1

    # Verify config persistence
    reloaded_cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    saved_dirs = reloaded_cfg.fetch("workspace.allowed_external_dirs")
    refute_includes saved_dirs, @allowed_dir1
    assert_includes saved_dirs, @allowed_dir2
  end

  def test_sandbox_runner_reconfigure_shrinks_config_removed_dirs
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    cfg.set("workspace.allowed_external_dirs", [@allowed_dir1, @allowed_dir3], persist: false)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_root, config: cfg)
    assert_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir1)
    assert_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir3)

    # Tighten the config: the allow-list key edit flips the runner into
    # config-authoritative mode via the dedicated on_change watcher, and the
    # prefix "sandbox" is not needed — ConfigWiring fires remove_allowed_dir
    # in a live shell; here we reconfigure directly to isolate Runner logic.
    cfg.set("workspace.allowed_external_dirs", [@allowed_dir1], persist: false)
    runner.reconfigure!

    assert_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir1)
    refute_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir3)
  end

  def test_sandbox_runner_reconfigure_preserves_runtime_added_dirs
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_root, config: cfg,
                                        allowed_external_dirs: [@allowed_dir1])

    # Baseline (constructor) and runtime-only dir both survive an unrelated
    # sandbox reconfigure (allow-list key untouched → nothing is recomputed).
    runner.add_allowed_dir(@allowed_dir2)
    cfg.set("sandbox.enabled", "false", persist: false)

    assert_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir1)
    assert_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir2)

    # Explicit remove_allowed_dir persists (does not resurrect on reconfigure).
    runner.remove_allowed_dir(@allowed_dir2)
    cfg.set("sandbox.enabled", "true", persist: false)
    refute_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir2)
  end

  def test_sandbox_runner_malformed_allowed_dirs_config_fails_closed
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    cfg.set("workspace.allowed_external_dirs", [@allowed_dir1, @allowed_dir3], persist: false)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_root, config: cfg)
    assert_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir1)

    # A malformed (non-Array) value after the key was touched must NOT leave
    # the previously-merged union live (fail-open). It is treated as an empty
    # authoritative config: config-sourced dirs are revoked, with a warning.
    cfg.set("workspace.allowed_external_dirs", "/not/an/array", persist: false)

    warn_output = capture_io { runner.reconfigure! }.last
    assert_includes warn_output, "must be an Array"
    refute_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir1)
    refute_includes runner.allowed_external_dirs, File.expand_path(@allowed_dir3)
  end

  def test_repl_allow_dir_alias_and_workspace_status
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    # Use !allow-dir alias
    shell.execute_input("!allow-dir #{@allowed_dir1}")
    assert_includes out.string, "[Rubik::Allow] Added allowed external directory: #{@allowed_dir1}"

    # Check !workspace list shows both workspace roots and allowed external dirs
    out.reopen
    shell.execute_input("!workspace list")
    assert_includes out.string, "=== Configured Workspace Roots ==="
    assert_includes out.string, "[PRIMARY] #{@temp_root}"
    assert_includes out.string, "=== Allowed External Dirs (Zero-AST) ==="
    assert_includes out.string, "[ALLOWED 1] #{@allowed_dir1} (Read-Write)"

    # Use !workspace allow
    out.reopen
    shell.execute_input("!workspace allow #{@allowed_dir2}")
    assert_includes out.string, "[Rubik::Allow] Added allowed external directory: #{@allowed_dir2}"
  end

  def test_repl_allow_blocks_dangerous_system_roots
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!allow /etc")
    assert_includes out.string, "Security Error"
    assert_includes out.string, "Adding dangerous system root as workspace is blocked"
    refute_includes shell.buffer_manager.allowed_external_dirs, "/etc"

    out.reopen
    shell.execute_input("!allow /")
    assert_includes out.string, "Security Error"
    refute_includes shell.buffer_manager.allowed_external_dirs, "/"
  end

  def test_config_set_syncs_allowed_external_dirs_without_ast_trigger
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!config set workspace.allowed_external_dirs [\"#{@allowed_dir1}\"]")
    assert_includes out.string, "Config 'workspace.allowed_external_dirs' updated"

    assert_includes shell.buffer_manager.allowed_external_dirs, @allowed_dir1
    assert_includes shell.sandbox_runner.allowed_paths, @allowed_dir1

    # Context index and AST graph remain untouched
    refute_includes shell.context_index.additional_roots, @allowed_dir1
  end
end
