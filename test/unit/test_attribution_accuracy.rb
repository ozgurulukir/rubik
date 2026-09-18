# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# Guard against ATTRIBUTION.md drifting out of sync with reality again:
# each pinned claim here was once stale (review 2026-09-17 follow-up).
class TestAttributionAccuracy < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOC  = File.join(ROOT, "ATTRIBUTION.md")
  GEMSPEC = File.join(ROOT, "rubik.gemspec")

  def setup
    @doc = File.read(DOC)
    @spec = Gem::Specification.load(GEMSPEC)
  end

  def test_command_yaml_count_claim_matches_disk
    actual = Dir.children(File.join(ROOT, "lib/rubik/security/classifier/commands")).size
    refute_equal 168, actual, "the stale '168+' claim resurfaced; refresh ATTRIBUTION.md"
    assert_includes @doc, "(#{actual} popular CLI tool definition YAML files",
                    "ATTRIBUTION.md must state the exact classifier command count (#{actual})"
  end

  def test_test_suite_claim_matches_badge_or_rake_baseline
    assert_includes @doc, "1,690+ unit, integration, and contract tests",
                    "ATTRIBUTION.md must cite the current suite size (badge says 1696 runs)"
  end

  def test_runtime_gem_dependencies_are_all_credited
    @spec.dependencies.select(&:runtime?).each do |dep|
      assert_includes @doc, dep.name,
                      "runtime gem '#{dep.name}' is declared in the gemspec but missing from ATTRIBUTION.md"
    end
  end

  def test_prism_is_declared_as_a_gemspec_dependency
    dep = @spec.dependencies.find { |d| d.name == "prism" }
    refute_nil dep, "prism is required by lib/rubik/ast/ruby_extractor.rb and must be a gemspec dependency"
    assert dep.runtime?, "prism dependency must be a runtime dependency"
  end

  def test_sandbox_section_covers_all_driver_classes
    driver_dir = File.join(ROOT, "lib/rubik/sandbox/driver")
    (Dir.children(driver_dir) - ["base.rb"]).each do |file|
      driver = File.basename(file, ".rb")
      assert_includes @doc, driver,
                      "ATTRIBUTION.md sandbox section must mention driver '#{driver}'"
    end
  end

  def test_documented_lib_paths_exist
    @doc.scan(%r{\[`?[\w:.]+`?\]\((lib/[^)#]+)\)}).flatten.uniq.each do |rel|
      assert File.exist?(File.join(ROOT, rel)), "ATTRIBUTION.md links to missing path: #{rel}"
    end
  end

  def test_documented_gem_names_are_real_gems_in_the_bundle
    bundled = Bundler.definition.specs.map(&:name)
    ["diff-lcs", "tty-prompt", "tty-spinner", "tty-markdown", "tty-which", "pastel", "strings-ansi", "reline", "prism", "minitest", "rubocop",
     "tree_sitter_language_pack"].each do |gem|
      assert_includes bundled, gem, "ATTRIBUTION.md credits '#{gem}' which is not in the current bundle"
    end
  end
end
