# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "rubik/runtime/overlay_guard"
require "rubik/security/errors"

# Unit tests for the REAL Rubik::Runtime::OverlayGuard (issue #447): the
# path-containment matrix and the fail-closed bootstrap screening gate.
# The synthesis guard is a recording spy — the class under test is the real
# OverlayGuard, never a stand-in.
class RecordingGuard
  attr_reader :screened

  def initialize(raises: nil)
    @raises = raises
    @screened = []
  end

  def verify_synthesis_safety!(code)
    raise @raises if @raises

    @screened << code
    true
  end
end

class TestOverlayGuard < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_guard_root")
    @overlay_dir = File.join(@root, ".rubik", "overlay")
    FileUtils.mkdir_p(@overlay_dir)
    @guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: RecordingGuard.new,
      trust_mode: -> { false }
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
    ENV.delete("RUBIK_BOOTSTRAP_OVERLAYS")
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # ── ensure_valid_overlay_dir! ──

  def test_valid_overlay_dir_passes
    assert_silent { @guard.ensure_valid_overlay_dir!(@overlay_dir) }
  end

  def test_valid_overlay_dir_accepts_normalized_variants
    assert_silent { @guard.ensure_valid_overlay_dir!("#{@overlay_dir}/") }
    assert_silent { @guard.ensure_valid_overlay_dir!(File.expand_path(@overlay_dir)) }
  end

  def test_foreign_dir_raises
    err = assert_raises(ArgumentError) { @guard.ensure_valid_overlay_dir!(@root) }
    assert_includes err.message, "Invalid overlay directory"
  end

  def test_nonexistent_dir_raises
    err = assert_raises(ArgumentError) { @guard.ensure_valid_overlay_dir!(File.join(@overlay_dir, "nope")) }
    assert_includes err.message, "Invalid overlay directory"
  end

  def test_lexically_equal_dir_outside_trusted_root_raises
    outside_root = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(outside_root)
    guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[outside_root, @overlay_dir]],
      guard: RecordingGuard.new,
      trust_mode: -> { false }
    )
    # The dir IS in the table, but it is not under its trusted root: rejected.
    err = assert_raises(ArgumentError) { guard.ensure_valid_overlay_dir!(outside_root) }
    assert_includes err.message, "Invalid overlay directory"
  end

  # ── ensure_contained_path! / safe_path_under? ──

  def test_contained_existing_path_passes
    path = File.join(@overlay_dir, "cmd.rb")
    File.write(path, "puts 'x'")
    assert_silent { @guard.ensure_contained_path!(path, @overlay_dir) }
    assert_equal true, @guard.safe_path_under?(path, @overlay_dir)
  end

  def test_contained_nonexistent_path_passes_via_resolved_check
    path = File.join(@overlay_dir, "not_yet.rb")
    assert_equal true, @guard.safe_path_under?(path, @overlay_dir)
  end

  def test_nested_nonexistent_path_under_existing_parent_passes
    path = File.join(@overlay_dir, "sub", "not_yet.rb")
    assert_equal true, @guard.safe_path_under?(path, @overlay_dir)
  end

  def test_dot_dot_traversal_is_refused
    path = File.join(@overlay_dir, "..", "escape.rb")
    err = assert_raises(ArgumentError) { @guard.ensure_contained_path!(path, @overlay_dir) }
    assert_includes err.message, "Path traversal attempt detected"
    assert_equal false, @guard.safe_path_under?(path, @overlay_dir)
  end

  def test_absolute_outside_path_is_refused
    outside = File.join(@root, "outside.rb")
    assert_equal false, @guard.safe_path_under?(outside, @overlay_dir)
  end

  def test_symlink_escaping_containment_is_refused
    outside_file = File.join(@root, "secret.rb")
    File.write(outside_file, "puts 'secret'")
    link = File.join(@overlay_dir, "innocent.rb")
    try_symlink(outside_file, link)

    assert_equal false, @guard.safe_path_under?(link, @overlay_dir)
    assert_raises(ArgumentError) { @guard.ensure_contained_path!(link, @overlay_dir) }
  end

  def test_symlink_into_sibling_overlay_dir_is_refused_even_when_target_is_another_allowed_dir
    # The escape hatch that matters: a link pointing at a DIFFERENT allowed
    # overlay dir must still fail THIS dir's containment (per-dir boundary).
    second_dir = File.join(@root, ".rubik", "overlay2")
    FileUtils.mkdir_p(second_dir)
    target = File.join(second_dir, "real.rb")
    File.write(target, "puts 'x'")
    link = File.join(@overlay_dir, "linked.rb")
    try_symlink(target, link)

    assert_equal false, @guard.safe_path_under?(link, @overlay_dir)
  end

  def test_symlink_to_internal_file_is_contained
    real = File.join(@overlay_dir, "real.rb")
    File.write(real, "puts 'x'")
    link = File.join(@overlay_dir, "alias.rb")
    try_symlink(real, link)

    assert_equal true, @guard.safe_path_under?(link, @overlay_dir)
  end

  def test_nil_arguments_fail_closed
    assert_equal false, @guard.safe_path_under?(nil, @overlay_dir)
    assert_equal false, @guard.safe_path_under?(File.join(@overlay_dir, "x.rb"), nil)
    assert_equal false, @guard.safe_path_under?(nil, nil)
  end

  def test_foreign_parent_dir_fails_closed_without_raising
    # safe_path_under? never raises: the ArgumentError from the dir validation
    # is swallowed into a false (deny) verdict.
    assert_equal false, @guard.safe_path_under?(File.join(@root, "x.rb"), @root)
  end

  def test_equal_path_to_parent_dir_is_contained
    assert_equal true, @guard.safe_path_under?(@overlay_dir, @overlay_dir)
  end

  # ── Trust / bootstrap screening ──

  def test_trust_mode_delegates_to_the_injected_callable
    refute @guard.trust_mode?
    guarded = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: RecordingGuard.new,
      trust_mode: -> { true }
    )
    assert guarded.trust_mode?
  end

  def test_bootstrap_opt_in_reads_the_env_gate
    ENV.delete("RUBIK_BOOTSTRAP_OVERLAYS")
    refute @guard.bootstrap_opt_in?
    ENV["RUBIK_BOOTSTRAP_OVERLAYS"] = "1"
    assert @guard.bootstrap_opt_in?
  end

  def test_screen_bootstrap_content_accepts_clean_content
    spy = RecordingGuard.new
    guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: spy,
      trust_mode: -> { false }
    )

    verdict = nil
    warnings = capture_stderr { verdict = guard.screen_bootstrap_content("puts 'clean'", "clean.rb") }

    assert_equal :ok, verdict
    assert_equal ["puts 'clean'"], spy.screened, "the injected guard must see the full content"
    assert_empty warnings
  end

  def test_screen_bootstrap_content_rejects_blocked_content
    guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: RecordingGuard.new(raises: Rubik::Security::BlockedWriteError),
      trust_mode: -> { false }
    )

    verdict = nil
    warnings = capture_stderr { verdict = guard.screen_bootstrap_content("system('rm -rf /')", "evil.rb") }

    assert_equal :rejected, verdict
    assert_match(/\[SECURITY\] Bootstrap overlay 'evil\.rb' refused by synthesis guard/, warnings)
  end

  def test_screen_bootstrap_content_is_fail_closed_on_guard_crash
    guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: RecordingGuard.new(raises: RuntimeError),
      trust_mode: -> { false }
    )

    verdict = nil
    warnings = capture_stderr { verdict = guard.screen_bootstrap_content("puts 'x'", "broken.rb") }

    assert_equal :rejected, verdict
    assert_match(/could not be screened \(RuntimeError: RuntimeError\); refusing/, warnings)
  end

  def test_screen_bootstrap_content_survives_system_stack_error
    guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: RecordingGuard.new(raises: SystemStackError),
      trust_mode: -> { false }
    )

    verdict = nil
    warnings = capture_stderr { verdict = guard.screen_bootstrap_content("puts 'x'", "deep.rb") }

    assert_equal :rejected, verdict
    assert_match(/could not be screened \(SystemStackError: SystemStackError\); refusing/, warnings)
  end

  def test_screen_bootstrap_content_rejects_when_no_guard_injected_and_default_explodes
    # guard: nil exercises the lazy default path — stub the default Guard to
    # keep the test hermetic while pinning the nil-kwarg resolution.
    guard = Rubik::Runtime::OverlayGuard.new(
      allowed_dirs: [[@overlay_dir, @root]],
      guard: nil,
      trust_mode: -> { false }
    )
    default_guard = Minitest::Mock.new
    default_guard.expect(:verify_synthesis_safety!, nil) do |_code|
      raise Rubik::Security::BlockedWriteError, "default guard refusal"
    end

    verdict = nil
    warnings = capture_stderr do
      Rubik::Security::Guard.stub(:new, default_guard) do
        verdict = guard.screen_bootstrap_content("puts 'x'", "defaulted.rb")
      end
    end

    assert_equal :rejected, verdict
    assert_match(/refused by synthesis guard/, warnings)
  end

  private

  def assert_silent(&)
    warnings = capture_stderr(&)
    assert_empty warnings, "expected no stderr output, got: #{warnings}"
  end
end
