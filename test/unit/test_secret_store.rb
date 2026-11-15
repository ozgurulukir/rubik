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

    assert store.available?
    assert_includes [:macos_keychain, :windows_credman, :linux_secret_service, :file], store.backend_name
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
