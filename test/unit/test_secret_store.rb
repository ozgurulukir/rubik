# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/security/secret_store"

# Unit coverage for Rubik::Security::SecretStore: the reference protocol,
# name validation, the owner-only file fallback, and backend argv shapes.
# OS keyring binaries are never invoked — the spawn seam (#run) is stubbed,
# and the argv builders are asserted as pure functions.
class TestSecretStore < Minitest::Test
  FAKE = "sk-test-not-a-real-credential"

  def setup
    @temp_dir = Dir.mktmpdir("rubik_secrets")
    Rubik::Security::SecretStore.reset!
  end

  def teardown
    Rubik::Security::SecretStore.reset!
    FileUtils.remove_entry(@temp_dir)
  end

  def test_reference_protocol
    store = Rubik::Security::SecretStore
    ref = store.reference_for("providers.openai.api_key")

    assert store.reference?(ref)
    refute store.reference?("sk-plain-legacy-value")
    refute store.reference?(nil)
    assert_equal "sk-plain-legacy-value", store.resolve("sk-plain-legacy-value")
  end

  def test_invalid_names_are_refused
    store = Rubik::Security::SecretStore

    assert_raises(Rubik::Security::SecretStore::Error) do
      store.set("bad name with spaces", FAKE)
    end
    assert_raises(Rubik::Security::SecretStore::Error) do
      store.set("providers.openai.api_key", "")
    end
  end

  def test_file_backend_roundtrip_and_owner_only
    skip "Windows does not model POSIX file modes" if Rubik::Platform.windows?

    path = File.join(@temp_dir, "secrets.yml")
    backend = Rubik::Security::SecretStore::FileBackend.new(path)

    backend.write("providers.openai.api_key", FAKE)
    backend.write("providers.anthropic.api_key", "sk-test-second-value")

    assert_equal FAKE, backend.read("providers.openai.api_key")
    assert_equal "sk-test-second-value", backend.read("providers.anthropic.api_key")
    assert_equal 0o600, File.stat(path).mode & 0o777

    backend.delete("providers.openai.api_key")
    assert_nil backend.read("providers.openai.api_key")
    assert_equal "sk-test-second-value", backend.read("providers.anthropic.api_key")
  end

  def test_file_backend_survives_corrupt_store
    path = File.join(@temp_dir, "secrets.yml")
    File.write(path, "not: [valid: yaml")
    backend = Rubik::Security::SecretStore::FileBackend.new(path)

    assert_nil backend.read("providers.openai.api_key")

    backend.write("providers.openai.api_key", FAKE)
    assert_equal FAKE, backend.read("providers.openai.api_key")
  end

  def test_module_routes_through_injected_backend
    store = Rubik::Security::SecretStore
    store.backend = MemoryBackend.new

    ref = store.set("providers.openai.api_key", FAKE)
    assert_equal "rubik-secret:providers.openai.api_key", ref
    assert_equal FAKE, store.fetch("providers.openai.api_key")
    assert_equal FAKE, store.resolve(ref)
    store.delete("providers.openai.api_key")
    assert_nil store.fetch("providers.openai.api_key")
  end

  def test_backend_name_reports_injected_backend_as_file
    Rubik::Security::SecretStore.backend = MemoryBackend.new

    # The class-name mapping only knows the shipped backend classes; a
    # foreign test double reports as :file by design.
    assert_equal :file, Rubik::Security::SecretStore.backend_name
  end

  def test_active_backend_is_a_known_kind_on_this_host
    store = Rubik::Security::SecretStore
    # Stub selection so no host keyring binary is ever probed; the point is
    # the name mapping, not host discovery.
    store.singleton_class.send(:alias_method, :__test_select_backend, :select_backend)
    store.define_singleton_method(:select_backend) { Rubik::Security::SecretStore::MacosKeychainBackend.new }
    assert_equal :macos_keychain, store.backend_name

    store.define_singleton_method(:select_backend) { Rubik::Security::SecretStore::FileBackend.new }
    store.reset! # drop the memoized first selection
    assert_equal :file, store.backend_name
  ensure
    store.singleton_class.send(:alias_method, :select_backend, :__test_select_backend)
    store.singleton_class.send(:remove_method, :__test_select_backend)
  end

  # --- argv shapes: pure functions, no spawn ---

  def test_macos_argv_keeps_secret_off_argv
    backend = Rubik::Security::SecretStore::MacosKeychainBackend.new
    argv = backend.send(:security_write_argv, "providers.openai.api_key")

    assert_equal ["-w"], argv.last(1) # flag without value: password via stdin
    refute_includes argv, FAKE
    assert_includes argv, "providers.openai.api_key"

    read_argv = backend.send(:security_read_argv, "providers.openai.api_key")
    assert_includes read_argv, "-w"
  end

  def test_linux_argv_passes_secret_via_stdin_contract
    backend = Rubik::Security::SecretStore::LinuxSecretToolBackend.new
    argv = backend.send(:store_argv, "providers.openai.api_key")

    refute_includes argv, FAKE
    assert_equal ["providers.openai.api_key"], argv.last(1)
    assert argv.include?("store")
  end

  def test_windows_scripts_are_frozen_and_interpolation_free
    scripts = [
      Rubik::Security::SecretStore::WindowsCredManBackend::WRITE_PS,
      Rubik::Security::SecretStore::WindowsCredManBackend::READ_PS,
      Rubik::Security::SecretStore::WindowsCredManBackend::DELETE_PS
    ]

    scripts.each do |script|
      assert_includes script, "$env:RUBIK_SECRET_NAME"
      refute_includes script, "\#{" # no Ruby interpolation survived
    end
  end

  # A minimal fake Process::Status (real one cannot be constructed).
  FakeStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  def test_windows_write_failure_raises_instead_of_silent_drop
    backend = Rubik::Security::SecretStore::WindowsCredManBackend.new
    backend.define_singleton_method(:run) do |_argv, **_opts|
      ["", "PasswordVault denied", FakeStatus.new(1)]
    end

    assert_raises(Rubik::Security::SecretStore::Error) do
      backend.write("providers.openai.api_key", FAKE)
    end
  end

  def test_windows_write_success_reports_ok
    backend = Rubik::Security::SecretStore::WindowsCredManBackend.new
    backend.define_singleton_method(:run) do |_argv, **_opts|
      ["ok", "", FakeStatus.new(0)]
    end

    assert backend.write("providers.openai.api_key", FAKE)
  end

  def test_macos_read_maps_denied_lookup_to_nil_not_empty_string
    backend = Rubik::Security::SecretStore::MacosKeychainBackend.new
    backend.define_singleton_method(:run) do |_argv, **_opts|
      ["", "SecKeychainSearchCopyNext: User interaction is not allowed.", FakeStatus.new(45)]
    end

    assert_nil backend.read("providers.openai.api_key")
  end

  def test_macos_read_maps_item_not_found_to_nil
    backend = Rubik::Security::SecretStore::MacosKeychainBackend.new
    backend.define_singleton_method(:run) do |_argv, **_opts|
      ["", "", FakeStatus.new(44)]
    end

    assert_nil backend.read("providers.openai.api_key")
  end

  def test_macos_read_returns_value_on_success
    backend = Rubik::Security::SecretStore::MacosKeychainBackend.new
    backend.define_singleton_method(:run) do |_argv, **_opts|
      ["#{FAKE}\n", "", FakeStatus.new(0)]
    end

    assert_equal FAKE, backend.read("providers.openai.api_key")
  end

  def test_scope_suffix_convention_is_shared
    policy = Rubik::Config::SecretPolicy

    assert_equal "providers.acme.api_key", policy.secret_name("providers.acme.api_key", :global)
    assert_equal "providers.acme.api_key", policy.secret_name("providers.acme.api_key", "global")
    assert_equal "providers.acme.api_key.project", policy.secret_name("providers.acme.api_key", :project)
    assert_equal "providers.acme.api_key", policy.secret_name("providers.acme.api_key", nil) # nil defaults to global
  end

  # Minimal in-memory stand-in for SecretStore.backend= injection.
  class MemoryBackend
    def initialize
      @saved = {}
    end

    def write(name, value)
      @saved[name] = value
    end

    def read(name)
      @saved[name]
    end

    def delete(name)
      @saved.delete(name)
      true
    end
  end
end
