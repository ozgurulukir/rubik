# frozen_string_literal: true

require_relative "../test_helper"

class TestSkillsFrontmatterAndValidator < Minitest::Test
  def test_parse_returns_frontmatter_and_body
    parsed = Rubik::Skills::Frontmatter.parse("---\nname: demo\ndescription: d\n---\n\n# Body\nline\n")
    assert_equal({ "name" => "demo", "description" => "d" }, parsed[:frontmatter])
    assert_equal("# Body\nline\n", parsed[:body])
  end

  def test_parse_preserves_horizontal_rules_in_body
    parsed = Rubik::Skills::Frontmatter.parse("---\nname: demo\ndescription: d\n---\n\nintro\n\n---\n\noutro\n")
    assert_includes parsed[:body], "---"
    assert_includes parsed[:body], "outro"
  end

  def test_parse_handles_crlf_and_bom
    parsed = Rubik::Skills::Frontmatter.parse("\uFEFF---\r\nname: demo\r\ndescription: d\r\n---\r\nbody\r\n")
    assert_equal({ "name" => "demo", "description" => "d" }, parsed[:frontmatter])
    assert_equal "body\n", parsed[:body]
  end

  def test_parse_rejects_missing_fences
    assert_raises(Rubik::Skills::Frontmatter::Error) { Rubik::Skills::Frontmatter.parse("no frontmatter here") }
    assert_raises(Rubik::Skills::Frontmatter::Error) { Rubik::Skills::Frontmatter.parse("---\nname: demo\n") }
  end

  def test_parse_rejects_non_mapping_and_broken_yaml
    assert_raises(Rubik::Skills::Frontmatter::Error) { Rubik::Skills::Frontmatter.parse("---\n- just\n- a list\n---\nbody\n") }
    assert_raises(Rubik::Skills::Frontmatter::Error) { Rubik::Skills::Frontmatter.parse("---\nname: [unclosed\n---\nbody\n") }
  end

  def test_validate_accepts_minimal_skill
    skill, issues = Rubik::Skills::Validator.validate(
      dir_name: "demo", root: "/x/demo", scope: :project, path: "/x/demo/SKILL.md",
      frontmatter: { "name" => "demo", "description" => "does things" }
    )
    refute_nil skill
    assert_equal "demo", skill.name
    assert_equal "does things", skill.description
    assert_equal :project, skill.scope
    assert_equal "/x/demo", skill.root
    assert_equal "/x/demo/SKILL.md", skill.path
    assert_empty issues
    assert_empty skill.warnings
  end

  def test_validate_accepts_maximal_skill
    skill, issues = Rubik::Skills::Validator.validate(
      dir_name: "demo", root: "/x/demo", scope: :user, path: "/x/demo/SKILL.md",
      frontmatter: {
        "name" => "demo", "description" => "d", "license" => "MIT", "compatibility" => "needs git",
        "metadata" => { "author" => "rubik", "version" => "1.0" }, "allowed-tools" => "run_command read_file"
      }
    )
    refute_nil skill
    assert_equal "MIT", skill.license
    assert_equal "needs git", skill.compatibility
    assert_equal({ "author" => "rubik", "version" => "1.0" }, skill.metadata)
    assert_equal %w[run_command read_file], skill.allowed_tools
    assert_empty issues
  end

  def test_validate_rejects_invalid_names
    ["-lead", "trail-", "dou--ble", "UPPER", "with_underscore", "a" * 65].each do |bad|
      skill, issues = validate_with(name: bad)
      assert_nil skill, "expected '#{bad}' to be rejected"
      assert issues.any? { |i| i.field == :name }
    end
  end

  def test_validate_rejects_name_directory_mismatch
    skill, issues = validate_with(name: "other")
    assert_nil skill
    assert issues.any? { |i| i.field == :name && i.message.include?("directory name") }
  end

  def test_validate_rejects_missing_and_oversized_description
    skill, issues = validate_with(name: "demo", drop_description: true)
    assert_nil skill
    assert issues.any? { |i| i.field == :description }

    skill2, issues2 = validate_with(name: "demo", description: "x" * 1025)
    assert_nil skill2
    assert issues2.any? { |i| i.field == :description && i.message.include?("exceeds") }
  end

  def test_validate_rejects_oversized_compatibility
    skill, issues = validate_with(name: "demo", compatibility: "c" * 501)
    assert_nil skill
    assert issues.any? { |i| i.field == :compatibility }
  end

  def test_validate_rejects_non_map_metadata
    skill, issues = validate_with(name: "demo", metadata: ["not", "a", "map"])
    assert_nil skill
    assert issues.any? { |i| i.field == :metadata }

    skill2, issues2 = validate_with(name: "demo", metadata: { "k" => 42 })
    assert_nil skill2
    assert issues2.any? { |i| i.field == :metadata }
  end

  def test_validate_warns_on_non_string_optional_fields
    skill, issues = validate_with(name: "demo", license: 42, "allowed-tools" => %w[read_file write_file])
    refute_nil skill, "array allowed-tools is a warning, not fatal"
    assert_nil skill.license
    assert_equal %w[read_file write_file], skill.allowed_tools
    assert issues.any? { |i| i.field == :license }
    assert issues.any? { |i| i.field == :"allowed-tools" && i.message.include?("space-separated") }
  end

  def test_validate_warns_on_unknown_keys
    skill, issues = validate_with(name: "demo", "descriptions" => "typo")
    refute_nil skill
    assert issues.any? { |i| i.field == :descriptions && i.message.include?("unknown frontmatter key") }
  end

  private

  def validate_with(name:, description: "does things", drop_description: false, **extra)
    frontmatter = { "name" => name }
    frontmatter["description"] = description unless drop_description
    extra.each { |k, v| frontmatter[k.to_s] = v }
    Rubik::Skills::Validator.validate(
      dir_name: "demo", root: "/x/demo", scope: :project, path: "/x/demo/SKILL.md", frontmatter: frontmatter
    )
  end
end
