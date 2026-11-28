# frozen_string_literal: true

require_relative "../test_helper"

# Issue #673: secret-shaped values must never reach a plaintext config,
# transcript, audit or storage record through an alternate entry point.
class TestSecretSecurity673 < Minitest::Test
  FAKE = "sk-fake-not-a-real-credential-1234"

  MemoryBackend = Class.new do
    attr_reader :saved

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

  def setup
    @root = Dir.mktmpdir("rubik_secret_security_673")
    @home = Dir.mktmpdir("rubik_secret_security_673_home")
    @backend = MemoryBackend.new
    Rubik::Security::SecretStore.backend = @backend
    @config = Rubik::Config.new(root_dir: @root, home_dir: @home)
  end

  def teardown
    Rubik::Security::SecretStore.reset!
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    FileUtils.remove_entry(@home) if @home && Dir.exist?(@home)
  end

  def test_secret_policy_recognizes_api_key_leaves_with_unusual_segments
    policy = Rubik::Config::SecretPolicy
    assert policy.secret_key?("providers.openai.api_key")
    ["a/b", "a@b", "a:b", "my work"].each do |segment|
      assert policy.secret_key?("providers.#{segment}.api_key"), "segment #{segment.inspect} must still be a secret leaf"
    end
  end

  def test_invalid_store_name_refuses_the_write_without_plaintext_fallback
    res = @config.set("providers.a/b.api_key", FAKE, persist: :global)

    refute res[:ok], "an unstorable secret must be refused, not written in plaintext"
    assert_match(/invalid secret store name/i, res[:error].to_s)
    refute File.exist?(File.join(@home, ".rubik", "config.yml"))
    assert_empty @backend.saved
  end

  def test_redactor_masks_common_credential_shapes
    redact = Rubik::Security::Redactor.method(:redact)
    [
      "Authorization: Basic dXNlcjpwYXNzd29yZA",
      '{"apiKey":"abcdefghijklmnopqrstuv"}',
      "accessKey=abcdefghijklmnopqrstuv",
      "privateKey=abcdefghijklmnopqrstuv",
      "private_key=abcdefghijklmnopqrstuv",
      "credential: abcdefghijklmnopqrstuv",
      "auth: hunter2"
    ].each do |text|
      assert_includes redact.call(text), Rubik::Security::Redactor::MASK_STRING, "not masked: #{text}"
    end
  end

  def test_mask_value_does_not_mask_the_author_field
    masked = Rubik::Security::Redactor.mask_value("author" => "Jane Doe", "auth" => "hunter2", "auth_tokens" => "secret-three")
    assert_equal "Jane Doe", masked["author"]
    assert_equal Rubik::Security::Redactor::MASK_STRING, masked["auth"]
    assert_equal Rubik::Security::Redactor::MASK_STRING, masked["auth_tokens"]
  end

  def test_session_recorder_masks_header_and_shell_credentials
    sessions = File.join(@root, "sessions")
    recorder = Rubik::Session::Recorder.new(sessions_dir: sessions, session_name: "s.jsonl")
    samples = [
      "Authorization: Basic dXNlcjpwYXNzd29yZA",
      "Cookie: session=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef",
      "token is xoxb-DUMMYDUMMYDUMMYDUMMY",
      "mysql -h localhost -u root -pSuperSecret123",
      "sshpass -p SuperSecret123 ssh user@host"
    ]
    samples.each { |text| recorder.record_tool_result("bash", text) }

    body = File.read(recorder.session_file)
    samples.each { |text| refute_includes body, text, "session transcript leaked #{text.inspect}" }
  end

  def test_session_and_audit_files_are_owner_only
    skip "Windows does not model POSIX file modes" if Rubik::Platform.windows?

    recorder = Rubik::Session::Recorder.new(sessions_dir: File.join(@root, "sessions"), session_name: "s.jsonl")
    recorder.record("note", "hello")
    audit = Rubik::Security::AuditLog.new(File.join(@root, "audit.log"))
    audit.log_audit("blocked_command", command: "echo hi")

    assert_equal 0o600, File.stat(recorder.session_file).mode & 0o777
    assert_equal 0o600, File.stat(audit.audit_log_path).mode & 0o777
  end

  def test_storage_tool_redacts_credentials_in_title_and_body
    store = Rubik::Storage::Store.new(root: File.join(@root, "storage"), project: "toolproj")
    tool = Rubik::Tools::StorageTool.new(store, root_dir: @root)
    tool.execute("action" => "put", "type" => "note",
                 "title" => "api_key=#{FAKE}",
                 "body" => "Authorization: Basic dXNlcjpwYXNzd29yZA")

    record = store.get(type: "note", id: "1")
    refute_includes record["title"], FAKE
    refute_includes record["body"], "dXNlcjpwYXNzd29yZA"
    assert_includes record["title"], Rubik::Security::Redactor::MASK_STRING
  end

  def test_mcp_env_credentials_are_not_persisted_in_plaintext
    manager = Rubik::MCP::Manager.new(config: @config, tools_registry: Rubik::Tools::Registry.new)
    token = "fake-github-token-for-tests"
    res = manager.add_server("fake", { "command" => "fake", "args" => [], "env" => { "GITHUB_TOKEN" => token } },
                             auto_start: false, persist: :global)

    assert res[:ok]
    disk = File.read(File.join(@home, ".rubik", "config.yml"))
    refute_includes disk, token, "MCP env credentials must not be persisted in plaintext"
    assert_equal token, @backend.read("mcp.servers.fake.env.GITHUB_TOKEN")
  end

  def test_secret_file_backend_wraps_permission_errors
    skip "root bypasses file permission bits" if Process.uid.zero?

    path = File.join(@root, "secrets.yml")
    File.write(path, "name: value\n")
    File.chmod(0o000, path)
    backend = Rubik::Security::SecretStore::FileBackend.new(path)

    error = assert_raises(Rubik::Security::SecretStore::Error) { backend.read("name") }
    assert_match(/Permission denied|read failed/, error.message)
  ensure
    File.chmod(0o644, path) if path && File.exist?(path)
  end
end
