# frozen_string_literal: true

require_relative "../test_helper"

class TestCLI < Minitest::Test
  def test_version_output
    output = `bin/rubik --version`
    assert_includes output, "rubik version #{Rubik::VERSION}"
  end
end
