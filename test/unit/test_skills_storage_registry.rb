# frozen_string_literal: true

require_relative "../test_helper"

class TestSkillsStorageRegistry < Minitest::Test
  def setup
    @project = Dir.mktmpdir("rubik_skills_project")
    @home = Dir.mktmpdir("rubik_skills_home")
    @extra = Dir.mktmpdir("rubik_skills_extra")
  end

  def teardown
    FileUtils.remove_entry(@project)
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@extra)
  end

  def write_skill(root, name, description: "d", body: "\nBody\n", extra_frontmatter: "")
    write_skill_md(File.join(root, ".rubik", "skills"), name,
                   description: description, body: body, extra_frontmatter: extra_frontmatter)
  end

  # Extra-path roots ARE skills roots (no .rubik/skills nesting below them).
  def write_direct(root, name, description: "d")
    write_skill_md(root, name, description: description)
  end

  def storage
    Rubik::Skills::Storage.new(root_dir: @project, home_dir: @home, extra_paths: [@extra])
  end

  def test_discovers_all_scopes
    write_skill(@project, "alpha")
    write_skill(@home, "beta")
    write_direct(@extra, "gamma")

    result = storage.discover
    assert_equal ["alpha", "beta", "gamma"], result.skills.map(&:name).sort
    assert_empty result.issues
    assert_equal :project, result.skills.find { |s| s.name == "alpha" }.scope
    assert_equal :user, result.skills.find { |s| s.name == "beta" }.scope
    assert_equal :extra, result.skills.find { |s| s.name == "gamma" }.scope
  end

  def test_extra_paths_missing_directory_is_tolerated
    storage = Rubik::Skills::Storage.new(root_dir: @project, home_dir: @home, extra_paths: ["/definitely/not/there"])
    assert_empty storage.discover.skills
  end

  def test_invalid_skills_are_skipped_with_issues
    write_skill(@project, "good")
    dir = File.join(@project, ".rubik", "skills", "broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\nname: not-the-dir\ndescription: d\n---\n")
    FileUtils.mkdir_p(File.join(@project, ".rubik", "skills", "no-skill-md"))

    result = storage.discover
    assert_equal ["good"], result.skills.map(&:name)
    assert(result.issues.any? { |i| i.field == :name && i.message.include?("directory name") })
    assert(result.issues.any? { |i| i.field == :skill_md })
  end

  def test_disabled_names_are_excluded_with_issue
    write_skill(@project, "alpha")
    write_skill(@project, "beta")

    result = storage.discover(disabled: ["beta"])
    assert_equal ["alpha"], result.skills.map(&:name)
    assert(result.issues.any? { |i| i.field == :disabled && i.message.include?("skills.disabled") })
  end

  def test_registry_precedence_project_beats_user_beats_extra
    write_skill(@project, "dupe", description: "project version")
    write_skill(@home, "dupe", description: "user version")
    write_direct(@extra, "dupe", description: "extra version")

    discovery = storage.discover
    registry = Rubik::Skills::Registry.new
    registry.install(discovery)

    assert_equal 1, registry.size
    assert_equal "project version", registry.find("dupe").description
    shadowed = registry.shadowed["dupe"]
    assert_equal :project, shadowed[:winner_scope]
    assert_equal [:user, :extra], shadowed[:loser_scopes], "every shadowed scope is recorded"
  end

  def test_registry_all_is_sorted_and_find_is_case_literal
    write_skill(@project, "zulu")
    write_skill(@project, "alpha")
    registry = Rubik::Skills::Registry.new
    registry.install(storage.discover)

    assert_equal ["alpha", "zulu"], registry.all.map(&:name)
    assert_equal "zulu", registry.find("zulu").name
    assert_nil registry.find("ZULU"), "names are matched literally"
    assert_nil registry.find("missing")
  end

  def test_zero_restart_reload_keeps_snapshot_stable
    write_skill(@project, "alpha")
    registry = Rubik::Skills::Registry.new
    100.times do |i|
      if i.even?
        write_skill(@project, "temp-#{i}")
      else
        FileUtils.rm_rf(File.join(@project, ".rubik", "skills", "temp-#{i - 1}"))
      end
      registry.install(storage.discover)
      assert_equal i.even? ? 2 : 1, registry.size, "install must reflect the exact on-disk state"
    end
    assert_equal ["alpha"], registry.all.map(&:name), "last install removed the temp skill"
  end
end
