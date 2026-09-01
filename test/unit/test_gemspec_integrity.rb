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
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new(RUBY_VERSION)),
           "Current Ruby version #{RUBY_VERSION} should satisfy gemspec requirement #{spec.required_ruby_version}"
  end
end
