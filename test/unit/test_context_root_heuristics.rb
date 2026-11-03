# frozen_string_literal: true

require_relative "../test_helper"

class TestContextRootHeuristics < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_home_equality_is_a_strong_signal
    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: @temp_dir)

    assert a.strong
    assert(a.reasons.any? { |r| r.include?("home") })
  end

  def test_filesystem_root_is_a_strong_signal
    # Parametrized: "C:/" is a filesystem root on Windows, "/" on POSIX.
    fs_root = Gem.win_platform? ? "C:/" : "/"
    a = Rubik::Context::RootHeuristics.assess(fs_root, home_dir: @temp_dir)

    assert a.strong
    assert(a.reasons.any? { |r| r.include?("filesystem root") })
  end

  def test_os_data_dir_at_root_is_a_strong_signal
    FileUtils.mkdir_p(File.join(@temp_dir, "AppData"))

    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil)

    assert a.strong
    assert(a.reasons.any? { |r| r.include?("OS data") })
  end

  def test_library_dir_at_root_is_a_strong_signal
    FileUtils.mkdir_p(File.join(@temp_dir, "Library"))

    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil)

    assert a.strong
  end

  def test_plain_project_dir_has_no_reasons_and_is_weak
    FileUtils.mkdir_p(File.join(@temp_dir, "src"))
    File.write(File.join(@temp_dir, "src", "main.rb"), "puts 1")

    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil, git_probe: ->(_d) { true })

    refute a.strong
    assert_empty a.reasons
  end

  def test_gitless_root_alone_is_weak_but_reported
    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil, git_probe: ->(_d) { false })

    refute a.strong
    assert(a.reasons.any? { |r| r.include?("not a git repository") })
  end

  def test_gitless_aggravator_joins_a_strong_signal
    FileUtils.mkdir_p(File.join(@temp_dir, "AppData"))

    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil, git_probe: ->(_d) { false })

    assert a.strong
    assert(a.reasons.any? { |r| r.include?("fallback walker") })
  end

  def test_dotgit_presence_short_circuits_the_probe
    FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
    raising_probe = ->(_d) { raise "probe must not run" }

    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil, git_probe: raising_probe)

    assert_empty a.reasons
  end

  def test_failing_probe_is_treated_as_gitless
    failing = ->(_d) { raise Errno::ENOENT, "git missing" }

    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil, git_probe: failing)

    refute a.strong
    assert(a.reasons.any? { |r| r.include?("not a git repository") })
  end

  def test_guidance_empty_for_clean_assessment
    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil, git_probe: ->(_d) { true })

    assert_equal "", Rubik::Context::RootHeuristics.guidance(a)
    assert_equal "", Rubik::Context::RootHeuristics.guidance(nil)
  end

  def test_guidance_names_the_escape_hatches
    FileUtils.mkdir_p(File.join(@temp_dir, "AppData"))
    a = Rubik::Context::RootHeuristics.assess(@temp_dir, home_dir: nil)

    g = Rubik::Context::RootHeuristics.guidance(a)

    assert_includes g, "context.exclude"
    assert_includes g, "!context scan"
  end
end
