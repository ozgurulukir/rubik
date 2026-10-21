# frozen_string_literal: true

require_relative "../test_helper"

class TestGemspecIntegrity < Minitest::Test
  def setup
    @gemspec_path = File.expand_path("../../rubik.gemspec", __dir__)
  end

  def test_gemspec_file_exists_and_loads_cleanly
    assert File.exist?(@gemspec_path), "rubik.gemspec must exist at repository root"

    spec = Gem::Specification.load(@gemspec_path)
    refute_nil spec, "rubik.gemspec should load successfully into Gem::Specification"
    assert_equal "rubik", spec.name
    assert_equal Rubik::VERSION, spec.version.to_s
    assert_equal "MIT", spec.license
    assert_includes spec.executables, "rubik"
  end

  def test_all_declared_files_exist_on_disk
    spec = Gem::Specification.load(@gemspec_path)
    root = File.expand_path("../..", __dir__)

    spec.files.each do |rel_file|
      full_path = File.join(root, rel_file)
      assert File.exist?(full_path), "File declared in gemspec missing on disk: #{rel_file}"
    end
  end

  def test_required_ruby_version_is_satisfied
    spec = Gem::Specification.load(@gemspec_path)
    unless spec.required_ruby_version.satisfied_by?(Gem::Version.new(RUBY_VERSION))
      skip "Current Ruby version #{RUBY_VERSION} is below declared gemspec floor #{spec.required_ruby_version}"
    end

    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new(RUBY_VERSION)),
           "Current Ruby version #{RUBY_VERSION} should satisfy gemspec requirement #{spec.required_ruby_version}"
  end

  # Reactive-wakeup floor (reline field report 2026-10-13): TerminalGuard#safe_wakeup!
  # injects an Enter via Reline.ungetc, which only reaches a reader already blocked
  # inside the gate's poll loop on reline >= 0.7.0; 0.6.x checks its ungetc buffer
  # once at getc entry, then waits on raw terminal input — the injected Enter
  # strands until the next keystroke (test/integration/test_reline_wakeup_contract.rb
  # pins the behavior end-to-end). Dropping the floor silently re-disables the idle
  # reactive wakeup on 0.6.x installs, so it must not escape a dependency cleanup.
  def test_reline_dependency_floors_the_reactive_wakeup_requirement
    spec = Gem::Specification.load(@gemspec_path)
    dep = spec.dependencies.find { |d| d.name == "reline" && d.type == :runtime }
    refute_nil dep, "gemspec must declare the reline runtime dependency"

    assert dep.requirement.satisfied_by?(Gem::Version.new("0.7.0")),
           "reline 0.7.0 must satisfy the declared requirement (#{dep.requirement})"
    refute dep.requirement.satisfied_by?(Gem::Version.new("0.6.3")),
           "reline 0.6.3 must NOT satisfy #{dep.requirement}: its getc strands the injected wake Enter"
  end
end
