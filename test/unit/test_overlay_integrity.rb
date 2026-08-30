# frozen_string_literal: true

require "test_helper"
require "rubik/runtime/overlay_storage"
class MockShell
  def register_command(*) end
  def instance_variable_get(*) end
end

class TestOverlayIntegrity < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("rubik_test_overlay")
    @storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp_dir, home_dir: @tmp_dir)
    @shell = MockShell.new
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if File.exist?(@tmp_dir)
    ENV.delete("RUBIK_TRUST_OVERLAYS")
  end

  def test_green_path_save_and_load
    res = @storage.save_command("hello", "puts 'hello'", scope: :project)
    assert res[:ok]

    loaded = @storage.load_all(@shell)
    assert_includes loaded, "hello"

    manifest = JSON.parse(File.read(File.join(@storage.project_commands_dir, ".manifest.json")))
    assert manifest.key?("hello.rb")
  end

  def test_tampered_file_is_rejected
    @storage.save_command("tampered", "puts 'ok'", scope: :project)

    path = File.join(@storage.project_commands_dir, "tampered.rb")
    original_content = File.read(path)
    File.write(path, original_content + "\n# evil code")

    # Capture warnings
    original_stderr = $stderr
    $stderr = StringIO.new

    loaded = @storage.load_all(@shell)
    $stderr.rewind
    warnings = $stderr.read

    $stderr = original_stderr

    refute_includes loaded, "tampered"
    assert_match(/\[SECURITY\] Integrity check failed for overlay 'tampered.rb'/, warnings)
  end

  def test_unknown_file_without_sentinel_rejected
    path = File.join(@storage.project_commands_dir, "unknown.rb")
    File.write(path, "puts 'bad'")

    # Mock manifest so we are in the "has manifest" or "bootstrap but no sentinel" branch
    @storage.save_manifest(@storage.project_commands_dir, {})

    original_stderr = $stderr
    $stderr = StringIO.new

    loaded = @storage.load_all(@shell)

    $stderr.rewind
    warnings = $stderr.read
    $stderr = original_stderr

    refute_includes loaded, "unknown"
    assert_match(/\[SECURITY\] Unknown overlay file 'unknown.rb'/, warnings)
  end

  def test_manifest_bootstrap_with_sentinel
    path = File.join(@storage.project_commands_dir, "bootstrap.rb")
    content = <<~RUBY
      # frozen_string_literal: true
      # Rubik Custom Command: !bootstrap
      # Scope: project
      # Description: bootstrap test

      puts 'bootstrapped'
    RUBY
    File.write(path, content)

    # Ensure no manifest exists
    manifest_file = File.join(@storage.project_commands_dir, ".manifest.json")
    FileUtils.rm_f(manifest_file)

    loaded = @storage.load_all(@shell)
    assert_includes loaded, "bootstrap"

    # Verify manifest was created
    assert File.exist?(manifest_file)
    manifest = JSON.parse(File.read(manifest_file))
    assert manifest.key?("bootstrap.rb")
  end

  def test_trust_mode_bypasses_integrity
    @storage.save_command("trusted", "puts 'ok'", scope: :project)
    path = File.join(@storage.project_commands_dir, "trusted.rb")
    File.write(path, File.read(path) + "\n# modified")

    ENV["RUBIK_TRUST_OVERLAYS"] = "1"

    loaded = @storage.load_all(@shell)
    assert_includes loaded, "trusted"
  end

  def test_multi_file_bootstrap_does_not_reject_second_file
    # RED-TEAM FIX: When no manifest exists and two sentinel files are in the dir,
    # the first file's bootstrap creates the manifest. The second file must also
    # bootstrap (not be rejected because it's "not in manifest").
    dir = @storage.project_commands_dir
    manifest_file = File.join(dir, ".manifest.json")
    FileUtils.rm_f(manifest_file)

    file_a = File.join(dir, "alpha.rb")
    File.write(file_a, "# frozen_string_literal: true\n# Rubik Custom Command: !alpha\n# Scope: project\n# Description: first\n\nputs 'alpha'\n")

    file_b = File.join(dir, "beta.rb")
    File.write(file_b, "# frozen_string_literal: true\n# Rubik Custom Command: !beta\n# Scope: project\n# Description: second\n\nputs 'beta'\n")

    loaded = @storage.load_all(@shell)
    assert_includes loaded, "alpha"
    assert_includes loaded, "beta"

    manifest = JSON.parse(File.read(manifest_file))
    assert manifest.key?("alpha.rb"), "alpha.rb should be in manifest"
    assert manifest.key?("beta.rb"), "beta.rb should be in manifest"
  end

  def test_corrupt_manifest_does_not_crash
    dir = @storage.project_commands_dir
    File.write(File.join(dir, ".manifest.json"), "NOT VALID JSON {{{")

    path = File.join(dir, "safe.rb")
    File.write(path, "# frozen_string_literal: true\n# Rubik Custom Command: !safe\n# Scope: project\n# Description: safe\n\nputs 'safe'\n")

    # Corrupt manifest → load_manifest returns {} → has_manifest=true but empty
    # File has sentinel → should bootstrap
    loaded = @storage.load_all(@shell)
    assert_includes loaded, "safe"
  end

  def test_empty_file_is_rejected_without_crash
    dir = @storage.project_commands_dir
    FileUtils.rm_f(File.join(dir, ".manifest.json"))

    File.write(File.join(dir, "empty.rb"), "")

    original_stderr = $stderr
    $stderr = StringIO.new

    loaded = @storage.load_all(@shell)

    $stderr.rewind
    warnings = $stderr.read
    $stderr = original_stderr

    refute_includes loaded, "empty"
    assert_match(/\[SECURITY\]/, warnings)
  end
end
