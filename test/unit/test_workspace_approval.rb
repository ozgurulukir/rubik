# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/repl/commands/workspace_approval"

# Focused unit coverage for the WorkspaceApproval and CommandPrefixApproval
# value objects extracted from repl/commands/workspace.rb (issue #474).
class TestWorkspaceApproval < Minitest::Test
  class FakeConfig
    attr_reader :stored

    def initialize(data = {})
      @data = data
      @stored = {}
    end

    def fetch(key, default = nil)
      @data.key?(key) ? @data[key] : default
    end

    def set(key, value, persist: nil)
      @stored[key] = [value, persist]
      { ok: true }
    end
  end

  class FakeBufferManager
    attr_reader :calls

    def initialize
      @calls = []
    end

    def add_root(path, rw:) # rubocop:disable Naming/MethodParameterName
      @calls << [:add_root, path, rw]
      File.expand_path(path)
    end

    def add_allowed_dir(path, rw:) # rubocop:disable Naming/MethodParameterName
      @calls << [:add_allowed_dir, path, rw]
      File.expand_path(path)
    end

    def remove_root(path)
      @calls << [:remove_root, path]
      File.expand_path(path)
    end

    def remove_allowed_dir(path)
      @calls << [:remove_allowed_dir, path]
      File.expand_path(path)
    end
  end

  class FakeSandboxRunner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def add_allowed_dir(path)
      @calls << [:add, path]
    end

    def remove_allowed_dir(path)
      @calls << [:remove, path]
    end
  end

  class FakeGuard
    attr_reader :audits

    def initialize(blocked: nil)
      @blocked = blocked
      @audits = []
    end

    def verify_root_safety!(path)
      raise Rubik::Security::BlockedWriteError, @blocked || "blocked #{path}" if @blocked
    end

    def verify_command_fallback_regex!(entry)
      raise Rubik::Security::BlockedWriteError, "catastrophic #{entry}" if @blocked
    end

    def log_audit(action, **kwargs)
      @audits << [action, kwargs]
    end
  end

  class StubClassifier
    DANGEROUS = Object.new.tap { |o| o.define_singleton_method(:classification) { :dangerous } }
    SAFE = Object.new.tap { |o| o.define_singleton_method(:classification) { :safe } }

    def initialize(classification:)
      @classification = classification
    end

    def classify(_token)
      @classification == :dangerous ? DANGEROUS : SAFE
    end
  end

  def setup
    @out = StringIO.new
  end

  def build_approval(read_write: true, scope: :project, config: FakeConfig.new, buffer_manager: FakeBufferManager.new,
                     guard: FakeGuard.new, sandbox_runner: FakeSandboxRunner.new, index_sync: -> { @synced = true },
                     effective_root: "/tmp/ws")
    approval = Rubik::REPL::Commands::WorkspaceApproval.new(
      path: "/tmp/ws/extra", read_write: read_write, scope: scope,
      config: config, buffer_manager: buffer_manager, out: @out,
      guard: guard, sandbox_runner: sandbox_runner, index_sync: index_sync,
      effective_root: effective_root
    )
    [approval, config, buffer_manager, sandbox_runner]
  end

  def test_trusted_true_when_guard_passes
    approval, = build_approval
    assert_equal true, approval.trusted?
    assert_empty @out.string
  end

  def test_trusted_false_prints_security_error_when_guard_blocks
    approval, = build_approval(guard: FakeGuard.new(blocked: "dangerous system root"))
    assert_equal false, approval.trusted?
    assert_includes @out.string, "Security Error: dangerous system root"
  end

  def test_add_root_registers_syncs_and_persists
    approval, config, buffer_manager, = build_approval(read_write: true)
    approval.add_root!

    assert_includes buffer_manager.calls, [:add_root, "/tmp/ws/extra", true]
    value, persist = config.stored["workspace.additional_roots"]
    assert_equal ["/tmp/ws/extra"], value
    assert_equal :project, persist
    assert_includes @out.string, "[Rubik::Workspace] Added additional root: /tmp/ws/extra (Mode: Read-Write) [Project level (.rubik/config.yml)]."
  end

  def test_add_root_skips_index_sync_when_auto_index_disabled
    synced = false
    config = FakeConfig.new("workspace.auto_index_additional" => false)
    approval, = build_approval(config: config, index_sync: -> { synced = true })
    approval.add_root!

    refute synced
  end

  def test_add_root_does_not_duplicate_persisted_entry
    config = FakeConfig.new("workspace.additional_roots" => ["/tmp/ws/extra"])
    approval, _, buffer_manager, = build_approval(config: config)
    approval.add_root!

    assert_equal ["/tmp/ws/extra"], config.stored["workspace.additional_roots"][0]
    assert_includes buffer_manager.calls, [:add_root, "/tmp/ws/extra", true]
  end

  def test_allow_dir_updates_buffer_sandbox_and_persists_without_index_sync
    synced = false
    approval, config, buffer_manager, sandbox = build_approval(read_write: false, index_sync: -> { synced = true })
    approval.allow_dir!

    assert_includes buffer_manager.calls, [:add_allowed_dir, "/tmp/ws/extra", false]
    assert_includes sandbox.calls, [:add, "/tmp/ws/extra"]
    refute synced # Zero-AST: allowed dirs never trigger index sync
    value, = config.stored["workspace.allowed_external_dirs"]
    assert_equal ["/tmp/ws/extra"], value
    assert_includes @out.string, "[Rubik::Allow] Added allowed external directory: /tmp/ws/extra (Mode: Read-Only)"
  end

  def test_remove_root_prunes_persisted_entries_by_expansion
    config = FakeConfig.new("workspace.additional_roots" => ["/tmp/ws/extra", "/tmp/ws/other", "extra"])
    approval, config2, buffer_manager, = build_approval(config: config)
    approval.remove_root!

    assert_includes buffer_manager.calls, [:remove_root, "/tmp/ws/extra"]
    remaining, = config2.stored["workspace.additional_roots"]
    assert_equal ["/tmp/ws/other"], remaining
    assert_includes @out.string, "[Rubik::Workspace] Removed additional root: /tmp/ws/extra"
  end

  def test_remove_allowed_dir_retracts_buffer_and_sandbox
    config = FakeConfig.new("workspace.allowed_external_dirs" => ["/tmp/ws/extra"])
    approval, config2, buffer_manager, sandbox = build_approval(config: config)
    approval.remove_allowed_dir!

    assert_includes buffer_manager.calls, [:remove_allowed_dir, "/tmp/ws/extra"]
    assert_includes sandbox.calls, [:remove, "/tmp/ws/extra"]
    remaining, = config2.stored["workspace.allowed_external_dirs"]
    assert_empty remaining
    assert_includes @out.string, "[Rubik::Allow] Removed allowed external directory: /tmp/ws/extra"
  end

  def build_prefix_approval(config: FakeConfig.new, guard: FakeGuard.new, classifier: StubClassifier.new(classification: :safe))
    approval = Rubik::REPL::Commands::CommandPrefixApproval.new(
      config: config, out: @out, guard: guard, classifier: classifier
    )
    [approval, config, guard]
  end

  def test_prefix_add_persists_entry_and_audits
    approval, config, guard = build_prefix_approval
    approval.add(["node", ".gitnexus/run.cjs"], :project)

    value, persist = config.stored["security.command_allowlist"]
    assert_equal ["node .gitnexus/run.cjs"], value
    assert_equal :project, persist
    assert_includes guard.audits, ["allowlist_add", { command: "node .gitnexus/run.cjs", scope: :project }]
    assert_includes @out.string, "[Rubik::AllowCmd] Added command prefix: node .gitnexus/run.cjs"
  end

  def test_prefix_add_rejects_empty_entry
    approval, config, = build_prefix_approval
    approval.add(["--force"], :session)

    assert_empty config.stored
    assert_includes @out.string, 'Usage: !allow-cmd add "<command prefix>"'
  end

  def test_prefix_add_blocks_broad_dangerous_token
    approval, config, = build_prefix_approval(classifier: StubClassifier.new(classification: :dangerous))
    approval.add(["node"], :session)

    assert_empty config.stored
    assert_includes @out.string, "Blocked: 'node' is a broad, single-token dangerous command"
  end

  def test_prefix_add_treats_classifier_crash_as_broad
    boom = Class.new(StandardError)
    crashing = Class.new do
      def initialize(raise_class); end

      def classify(_token)
        raise boom, "exploded"
      end
    end.new(boom)
    approval, config, = build_prefix_approval(classifier: crashing)
    approval.add(["node"], :session)

    assert_empty config.stored
    assert_includes @out.string, "Blocked: 'node' is a broad"
  end

  def test_prefix_add_blocks_catastrophic_pattern
    approval, config, = build_prefix_approval(guard: FakeGuard.new(blocked: "rm -rf"))
    approval.add(["rm", "-rf", "/"], :session)

    assert_empty config.stored
    assert_includes @out.string, "Blocked: 'rm -rf /' matches a catastrophic destructive pattern"
  end

  def test_prefix_add_reports_duplicate_without_resetting
    config = FakeConfig.new("security.command_allowlist" => ["node run"])
    approval, = build_prefix_approval(config: config)
    approval.add(["node", "run"], :session)

    assert_empty config.stored
    assert_includes @out.string, "'node run' is already allowlisted."
  end

  def test_prefix_remove_deletes_entry_and_audits
    config = FakeConfig.new("security.command_allowlist" => ["node run"])
    approval, config2, guard = build_prefix_approval(config: config)
    approval.remove("node run", :global)

    value, persist = config2.stored["security.command_allowlist"]
    assert_empty value
    assert_equal :global, persist
    assert_includes guard.audits, ["allowlist_remove", { command: "node run", scope: :global }]
    assert_includes @out.string, "[Rubik::AllowCmd] Removed command prefix: node run"
  end

  def test_prefix_remove_reports_missing_entry
    approval, config, = build_prefix_approval
    approval.remove("ghost", :session)

    assert_empty config.stored
    assert_includes @out.string, "'ghost' is not in the allowlist."
  end
end
