# frozen_string_literal: true

require_relative "../test_helper"

# Boot-time config observability (issue #399): Config#warnings accumulated
# unknown-key, corrupt-YAML and env-deprecation problems with no reader, so
# config mistakes surfaced nowhere at startup. Lifecycle#maybe_emit_config_warnings!
# prints them through the notices seam once per boot (dedup across warm_up!
# calls) and mirrors them via Rubik::Log.warn for headless boots. The retired
# network.allow alias gets its tailored deprecation from validate_schema
# (RETIRED_KEYS) instead of the generic unknown-key line.
class TestConfigBootNotices < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
  end

  def teardown
    remove_temp_dir(@temp_dir)
    remove_temp_dir(@temp_home)
  end

  def test_unknown_key_surfaces_config_notice_at_boot
    write_global_config("unknown_setting" => "val")
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell, io = boot_shell(config)

    assert_includes io.string, "⚠ Config: Unknown config key 'unknown_setting'."
  ensure
    shell&.stop
  end

  def test_clean_config_prints_no_config_notice
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_empty config.warnings
    shell, io = boot_shell(config)

    refute_includes io.string, "⚠ Config:"
  ensure
    shell&.stop
  end

  def test_boot_notice_emits_once_across_double_warm_up
    write_global_config("unknown_setting" => "val")
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell, io = boot_shell(config)
    assert_equal 1, io.string.scan("⚠ Config:").length

    shell.warm_up!
    assert_equal 1, io.string.scan("⚠ Config:").length
  ensure
    shell&.stop
  end

  def test_corrupt_yaml_surfaces_config_notice_at_boot
    File.write(File.join(@temp_dir, "rubik.yml"), "invalid: yaml: [")
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell, io = boot_shell(config)

    assert_includes io.string, "⚠ Config: Cannot load config because"
  ensure
    shell&.stop
  end

  def test_legacy_env_deprecation_surfaces_config_notice_at_boot
    snapshot = snapshot_env("RUBIK_NATIVE")
    ENV["RUBIK_NATIVE"] = "off"
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert(config.warnings.any? { |w| w.include?("RUBIK_NATIVE") },
           "expected the legacy env deprecation in #{config.warnings.inspect}")
    shell, io = boot_shell(config)

    assert_includes io.string, "⚠ Config: [DEPRECATION] Environment variable 'RUBIK_NATIVE' is deprecated."
  ensure
    shell&.stop
    restore_env(snapshot)
  end

  def test_retired_network_allow_emits_tailored_deprecation
    write_global_config("network" => { "allow" => true })
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert(
      config.warnings.any? do |w|
        w.include?("[DEPRECATION]") && w.include?("network.allow") && w.include?("sandbox.allow_network")
      end,
      "expected the tailored deprecation in #{config.warnings.inspect}"
    )
    assert_empty(config.warnings.grep(/Unknown config key 'network'/))

    shell, io = boot_shell(config)
    assert_includes io.string,
                    "⚠ Config: [DEPRECATION] Config key 'network.allow' is deprecated and has no effect. " \
                    "Use 'sandbox.allow_network' instead."
  ensure
    shell&.stop
  end

  private

  def write_global_config(hash)
    global_dir = File.join(@temp_home, ".rubik")
    FileUtils.mkdir_p(global_dir)
    File.write(File.join(global_dir, "config.yml"), YAML.dump(hash))
  end

  # Lightest Shell boot fixture (test_shell_coeffect pattern): the notices
  # seam prints through the TerminalGuard built over the captured StringIO.
  def boot_shell(config)
    io = StringIO.new
    shell = Rubik::REPL::Shell.new(config: config, output: io)
    [shell, io]
  end
end
