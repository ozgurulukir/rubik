# frozen_string_literal: true

require_relative "../test_helper"

class TestCLI < Minitest::Test
  def test_version_output
    cmd = Rubik::Platform.windows? ? "ruby bin/rubik --version" : "bin/rubik --version"
    output = `#{cmd}`
    assert_includes output, "rubik version #{Rubik::VERSION}"
  end
end
