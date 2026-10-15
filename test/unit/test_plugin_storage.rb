# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../../lib/rubik/plugin/storage"

class TestPluginStorage < Minitest::Test
  def setup
    @tmp_root = Dir.mktmpdir
    @tmp_home = Dir.mktmpdir
    ENV["RUBIK_TRUST_OVERLAYS"] = nil
    @storage = Rubik::Plugin::Storage.new(root_dir: @tmp_root, home_dir: @tmp_home)
  end

  def teardown
    FileUtils.rm_rf(@tmp_root)
    FileUtils.rm_rf(@tmp_home)
  end

  def test_ensure_directories
    assert Dir.exist?(@storage.project_plugins_dir)
    assert Dir.exist?(@storage.global_plugins_dir)
  end

  def test_add_and_remove_file_plugin
    dummy_plugin = File.join(@tmp_root, "my_plugin.rb")
    File.write(dummy_plugin, "puts 'hello'")

    res = @storage.add_plugin(dummy_plugin, scope: :project)
    assert res[:ok]
    assert_equal "my_plugin", res[:name]

    plugins = @storage.discover_plugins(scope: :project)
    assert_equal 1, plugins.size
    assert_equal "my_plugin", plugins.first[:name]

    assert_equal :verified, @storage.verify_integrity(res[:path], scope: :project)

    # Tampering test
    File.write(res[:path], "puts 'hacked'")
    assert_equal :rejected, @storage.verify_integrity(res[:path], scope: :project)

    # Trust overlays test
    ENV["RUBIK_TRUST_OVERLAYS"] = "1"
    assert_equal :trusted, @storage.verify_integrity(res[:path], scope: :project)
    ENV["RUBIK_TRUST_OVERLAYS"] = nil

    res = @storage.remove_plugin("my_plugin", scope: :project)
    assert res[:ok]
    assert_empty @storage.discover_plugins(scope: :project)
  end

  def test_add_and_remove_directory_plugin
    dummy_dir = File.join(@tmp_root, "my_pack")
    FileUtils.mkdir_p(File.join(dummy_dir, "lib"))
    File.write(File.join(dummy_dir, "lib", "my_pack.rb"), "puts 'pack'")

    res = @storage.add_plugin(dummy_dir, scope: :global)
    assert res[:ok]
    assert_equal "my_pack", res[:name]
    assert_equal :directory, res[:type]

    plugins = @storage.discover_plugins(scope: :global)
    assert_equal 1, plugins.size
    assert_equal "my_pack", plugins.first[:name]

    res = @storage.remove_plugin("my_pack", scope: :global)
    assert res[:ok]
    assert_empty @storage.discover_plugins(scope: :global)
  end

  # ── Issue #144: the manifest covers the WHOLE package ────────────────

  def write_package_source(name, entry:, helpers: {})
    dir = File.join(@tmp_root, name)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "#{name}.rb"), entry)
    helpers.each do |rel, body|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    dir
  end

  def installed_entry(name, scope: :project)
    meta = @storage.discover_plugins(scope: scope).find { |p| p[:name] == name }
    meta && meta[:path]
  end

  def test_directory_package_integrity_covers_helpers
    source = write_package_source("pack_a",
                                  entry: "require_relative 'helper'",
                                  helpers: { "lib/helper.rb" => "HELPER_V1 = 1" })
    res = @storage.add_plugin(source, scope: :project)
    assert res[:ok]

    entry = installed_entry("pack_a")
    refute_nil entry
    assert_equal :verified, @storage.verify_integrity(entry, scope: :project)

    # Helper modification is package drift — not a silent verification success.
    helper = File.join(res[:path], "lib", "helper.rb")
    File.write(helper, "HELPER_V1 = 2")
    _out, err = capture_io { assert_equal :rejected, @storage.verify_integrity(entry, scope: :project) }
    assert_includes err, "modified: lib/helper.rb"

    File.write(helper, "HELPER_V1 = 1")
    assert_equal :verified, @storage.verify_integrity(entry, scope: :project)
  end

  def test_directory_package_integrity_detects_added_and_removed_files
    source = write_package_source("pack_b",
                                  entry: "require_relative 'helper'",
                                  helpers: { "lib/helper.rb" => "HELPER = 1" })
    res = @storage.add_plugin(source, scope: :project)
    assert res[:ok]
    entry = installed_entry("pack_b")

    added = File.join(res[:path], "lib", "extra.rb")
    File.write(added, "EXTRA = 1")
    _out, err = capture_io { assert_equal :rejected, @storage.verify_integrity(entry, scope: :project) }
    assert_includes err, "added: lib/extra.rb"

    FileUtils.rm_f(added)
    assert_equal :verified, @storage.verify_integrity(entry, scope: :project)

    FileUtils.rm_f(File.join(res[:path], "lib", "helper.rb"))
    _out, err = capture_io { assert_equal :rejected, @storage.verify_integrity(entry, scope: :project) }
    assert_includes err, "removed: lib/helper.rb"
  end

  def test_directory_package_symlink_entry_is_rejected
    source = write_package_source("pack_link", entry: "require_relative 'helper'",
                                               helpers: { "lib/helper.rb" => "HELPER = 1" })
    outside = File.join(@tmp_root, "outside_secret.rb")
    File.write(outside, "SECRET = 1")
    File.symlink(outside, File.join(source, "lib", "escape.rb"))

    res = @storage.add_plugin(source, scope: :project)
    refute res[:ok], "a package with a symlink must not be added"
    assert_includes res[:error], "symlink"

    # And a symlink planted after consent is integrity drift, not a pass.
    source_clean = write_package_source("pack_link2", entry: "require_relative 'helper'",
                                                      helpers: { "lib/helper.rb" => "HELPER = 1" })
    res = @storage.add_plugin(source_clean, scope: :project)
    assert res[:ok]
    File.symlink(outside, File.join(res[:path], "lib", "escape.rb"))
    entry = installed_entry("pack_link2")
    _out, err = capture_io { assert_equal :rejected, @storage.verify_integrity(entry, scope: :project) }
    assert_includes err, "symlink"
  end

  def test_legacy_directory_manifest_requires_re_consent
    # A pre-package manifest hashed only the entry file; helpers were never
    # consented to, so the package must be rejected and re-added explicitly.
    dir = File.join(@storage.project_plugins_dir, "legacy_pack")
    FileUtils.mkdir_p(File.join(dir, "lib"))
    entry = File.join(dir, "lib", "legacy_pack.rb")
    File.write(entry, "puts 'legacy'")

    @storage.save_manifest(@storage.project_plugins_dir,
                           "legacy_pack.rb" => { "sha256" => Digest::SHA256.hexdigest("puts 'legacy'"),
                                                 "scope" => "project" })

    _out, err = capture_io { assert_equal :rejected, @storage.verify_integrity(entry, scope: :project) }
    assert_includes err, "no package inventory"
    assert_includes err, "!plugin add"
  end

  def test_add_rejects_package_without_entry_file
    dir = File.join(@tmp_root, "no_entry")
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "something_else.rb"), "puts 'x'")

    res = @storage.add_plugin(dir, scope: :project)
    refute res[:ok]
    assert_includes res[:error], "no entry file"
    refute File.exist?(File.join(@storage.project_plugins_dir, "no_entry"))
  end

  def test_remove_directory_plugin_cleans_package_manifest
    source = write_package_source("pack_rm", entry: "puts 'x'")
    res = @storage.add_plugin(source, scope: :project)
    assert res[:ok]
    assert @storage.load_manifest(@storage.project_plugins_dir).key?("pack_rm")

    assert @storage.remove_plugin("pack_rm", scope: :project)[:ok]
    refute @storage.load_manifest(@storage.project_plugins_dir).key?("pack_rm")
    refute @storage.load_manifest(@storage.project_plugins_dir).key?("pack_rm.rb")
  end

  def test_single_file_plugin_verification_unchanged
    file = File.join(@tmp_root, "one_file.rb")
    File.write(file, "puts 'one'")
    res = @storage.add_plugin(file, scope: :project)
    assert res[:ok]
    assert_equal :verified, @storage.verify_integrity(res[:path], scope: :project)

    File.write(res[:path], "puts 'changed'")
    assert_equal :rejected, @storage.verify_integrity(res[:path], scope: :project)
  end

  def test_path_outside_plugins_dir_is_not_verified
    outside = File.join(@tmp_root, "rogue.rb")
    File.write(outside, "puts 'rogue'")
    assert_equal :rejected, @storage.verify_integrity(outside, scope: :project)
  end
end
