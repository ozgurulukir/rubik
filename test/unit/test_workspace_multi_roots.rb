# frozen_string_literal: true

require_relative "../test_helper"

class TestWorkspaceMultiRoots < Minitest::Test
  def setup
    @primary_dir = Dir.mktmpdir("rubik_primary_ws")
    @extra_dir1 = Dir.mktmpdir("rubik_extra_ws1")
    @extra_dir2 = Dir.mktmpdir("rubik_extra_ws2")
    @unauthorized_dir = Dir.mktmpdir("rubik_unauthorized_ws")

    # Create files in primary dir
    FileUtils.mkdir_p(File.join(@primary_dir, "lib"))
    File.write(File.join(@primary_dir, "lib", "main.rb"), "puts 'primary main'")

    # Create files in extra dir 1 (e.g. shared library)
    FileUtils.mkdir_p(File.join(@extra_dir1, "proto"))
    File.write(File.join(@extra_dir1, "proto", "user.go"), "package proto\ntype User struct {}")

    # Create files in extra dir 2 (e.g. contracts)
    File.write(File.join(@extra_dir2, "schema.json"), '{"type": "object"}')

    # Create files in unauthorized dir
    File.write(File.join(@unauthorized_dir, "secret.txt"), "secret_data")
  end

  def teardown
    FileUtils.remove_entry(@primary_dir) rescue nil
    FileUtils.remove_entry(@extra_dir1) rescue nil
    FileUtils.remove_entry(@extra_dir2) rescue nil
    FileUtils.remove_entry(@unauthorized_dir) rescue nil
  end

  def test_buffer_reads_from_primary_and_additional_roots
    manager = Rubik::Buffer::Manager.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1, @extra_dir2],
      allow_external_writes: false
    )

    # Read primary file
    assert_equal "puts 'primary main'", manager.read("lib/main.rb")

    # Read extra root 1 file
    extra1_file = File.join(@extra_dir1, "proto", "user.go")
    assert_equal "package proto\ntype User struct {}", manager.read(extra1_file)

    # Read extra root 2 file
    extra2_file = File.join(@extra_dir2, "schema.json")
    assert_equal '{"type": "object"}', manager.read(extra2_file)
  end

  def test_blocks_access_to_unauthorized_paths
    manager = Rubik::Buffer::Manager.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1]
    )

    unauthorized_file = File.join(@unauthorized_dir, "secret.txt")
    assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.read(unauthorized_file)
    end

    assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.write(unauthorized_file, "hacked")
    end
  end

  def test_blocks_external_writes_by_default
    manager = Rubik::Buffer::Manager.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1],
      allow_external_writes: false
    )

    extra_file = File.join(@extra_dir1, "proto", "user.go")

    # Reading is fine
    refute_nil manager.read(extra_file)

    # Writing is blocked
    err = assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.write(extra_file, "package proto\n// modified")
    end
    assert_includes err.message, "Write blocked on external workspace root"
  end

  def test_allows_external_writes_when_configured_globally
    manager = Rubik::Buffer::Manager.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1],
      allow_external_writes: true
    )

    extra_file = File.join(@extra_dir1, "proto", "user.go")
    manager.write(extra_file, "package proto\n// updated version")

    assert manager.dirty?
    assert_equal "package proto\n// updated version", manager.read(extra_file)

    # Verify disk is unchanged until apply!
    assert_includes File.read(extra_file), "type User struct"

    # Apply changes
    applied = manager.apply!
    assert_includes applied, extra_file
    refute manager.dirty?

    # Verify disk is now updated
    assert_equal "package proto\n// updated version", File.read(extra_file)
  end

  def test_allows_writes_when_root_added_with_rw_flag
    manager = Rubik::Buffer::Manager.new(
      root_dir: @primary_dir,
      additional_roots: [],
      allow_external_writes: false
    )

    # Add extra_dir1 with rw: true
    manager.add_root(@extra_dir1, rw: true)
    # Add extra_dir2 with rw: false (default)
    manager.add_root(@extra_dir2, rw: false)

    extra1_file = File.join(@extra_dir1, "proto", "user.go")
    extra2_file = File.join(@extra_dir2, "schema.json")

    # Writing to extra_dir1 succeeds
    manager.write(extra1_file, "// rw root change")
    assert_equal "// rw root change", manager.read(extra1_file)

    # Writing to extra_dir2 fails
    assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.write(extra2_file, "{}")
    end
  end

  def test_dynamic_add_and_remove_root
    manager = Rubik::Buffer::Manager.new(root_dir: @primary_dir)

    extra_file = File.join(@extra_dir1, "proto", "user.go")

    # Before adding, read fails
    assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.read(extra_file)
    end

    # Add root
    manager.add_root(@extra_dir1)
    assert_equal "package proto\ntype User struct {}", manager.read(extra_file)

    # Remove root
    manager.remove_root(@extra_dir1)
    assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.read(extra_file)
    end
  end

  def test_security_guard_blocks_dangerous_system_roots
    audit_file = File.join(@primary_dir, "audit.log")
    guard = Rubik::Security::Guard.new(audit_log_path: audit_file)

    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_root_safety!("/")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_root_safety!("/etc")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_root_safety!("/home")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_root_safety!("~")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_root_safety!(ENV["HOME"])
    end

    # Safe root should pass
    assert guard.verify_root_safety!(@extra_dir1)
    assert guard.verify_root_safety!("./relative/path")
  end

  def test_context_scanner_and_index_scans_additional_roots
    scanner = Rubik::Context::Scanner.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1, @extra_dir2]
    )

    files = scanner.scan
    langs = scanner.detect_languages(files)

    assert_includes files.keys, "lib/main.rb"
    assert_includes langs, "ruby"
    assert_includes langs, "go"

    index = Rubik::Context::Index.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1, @extra_dir2]
    )

    scanned = index.full_scan
    assert_includes scanned.keys, "lib/main.rb"
    assert_includes index.languages, "ruby"
    assert_includes index.languages, "go"
  end

  def test_diff_and_snapshot_with_external_roots
    manager = Rubik::Buffer::Manager.new(
      root_dir: @primary_dir,
      additional_roots: [@extra_dir1],
      allow_external_writes: true
    )

    extra_file = File.join(@extra_dir1, "proto", "user.go")
    manager.write("lib/main.rb", "puts 'primary updated'")
    manager.write(extra_file, "package proto\ntype User struct { ID int }")

    diff = manager.diff_all
    assert_includes diff, "lib/main.rb"
    assert_includes diff, extra_file
    assert_includes diff, "+puts 'primary updated'"
    assert_includes diff, "+type User struct { ID int }"

    snapshot = manager.snapshot_state
    assert_equal "puts 'primary updated'", snapshot["lib/main.rb"]
    assert_equal "package proto\ntype User struct { ID int }", snapshot[extra_file]

    manager.reset!
    refute manager.dirty?

    manager.restore_snapshot_state(snapshot)
    assert manager.dirty?
    assert_equal "puts 'primary updated'", manager.read("lib/main.rb")
    assert_equal "package proto\ntype User struct { ID int }", manager.read(extra_file)
  end

  def test_add_relative_root_path
    manager = Rubik::Buffer::Manager.new(root_dir: @primary_dir)
    rel_path = Pathname.new(@extra_dir1).relative_path_from(Pathname.new(@primary_dir)).to_s

    expanded = manager.add_root(rel_path, rw: true)
    assert_equal File.expand_path(@extra_dir1), expanded
    assert_includes manager.additional_roots, File.expand_path(@extra_dir1)

    extra_file = File.join(@extra_dir1, "proto", "user.go")
    manager.write(extra_file, "// relative root write")
    assert_equal "// relative root write", manager.read(extra_file)
  end
end
