# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "rubygems/package"

# Publication contract for the `rubik` gem: the gemspec builds a complete,
# leak-free package. Pins the D1/D4 rulings (ruby floor, contact email) and
# the file-list boundaries (runtime data in, dev wrappers and scratch out).
# Plan: _plan/gem-publication-2026-10-09.md (S3).
class TestGemPackage < Minitest::Test
  def setup
    @root = File.expand_path("../..", __dir__)
    @spec = Gem::Specification.load(File.join(@root, "rubik.gemspec"))
    refute_nil @spec, "rubik.gemspec must load"
  end

  def teardown
    # remove_temp_dir (test_helper) carries the Windows EACCES retry; it
    # removes files as well as dirs, so the built .gem goes through it too.
    remove_temp_dir(File.join(@root, "pkg"))
    Dir.glob(File.join(@root, "rubik-*.gem")).each { |g| remove_temp_dir(g) }
  end

  def test_d1_ruby_floor_matches_the_tested_surface
    assert @spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.4.0")),
           "Ruby 3.4 must satisfy the requirement"
    refute @spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.3.2")),
           "Ruby 3.3 must stay outside the claim (untested surface)"
  end

  def test_d4_contact_email_is_the_project_address_only
    assert_equal ["info@rubik.dev"], @spec.email
  end

  def test_metadata_links_are_complete
    ["source_code_uri", "changelog_uri", "bug_tracker_uri"].each do |key|
      assert @spec.metadata[key].to_s.start_with?("https://"),
             "metadata[#{key}] must be an https link, got #{@spec.metadata[key].inspect}"
    end
    assert_equal "true", @spec.metadata["rubygems_mfa_required"]
  end

  def test_built_package_contents_match_the_publication_contract
    # Gem::Package.build writes into the cwd and returns the file name.
    gem_name = Dir.chdir(@root) { Gem::Package.build(@spec) }
    path = File.join(@root, gem_name)
    assert File.exist?(path), "built gem missing: #{path}"

    contents = Gem::Package.new(path).contents

    [
      "lib/rubik.rb",
      "bin/rubik",
      "README.md",
      "LICENSE",
      "CHANGELOG.md",
      "ATTRIBUTION.md",
      "lib/rubik/security/classifier/commands/bash.yaml"
    ].each { |f| assert_includes contents, f, "package must ship #{f}" }

    [
      "bin/rubik.bat",
      "bin/rubik.cmd",
      "bin/rubik.ps1",
      "rubik.gemspec",
      "test/unit/test_gem_package.rb"
    ].each { |f| refute_includes contents, f, "package must not ship #{f}" }
  end
end
