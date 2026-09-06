# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/parsers/powershell"

class TestCommandClassifierPwshParser < Minitest::Test
  Parser = Rubik::Security::Classifier::Parsers::PowerShell

  def test_parse_cmdlet_with_parameters
    invs, warns = Parser.parse("Remove-Item -Recurse C:\\temp")
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["Remove-Item", "-Recurse", "C:\\temp"], invs[0].argv
  end

  def test_parse_pipeline
    invs, warns = Parser.parse("Get-Process | Stop-Process -Force")
    assert_empty warns
    assert_equal 2, invs.size

    assert_equal ["Get-Process"], invs[0].argv
    assert_equal 0, invs[0].position_in_pipeline
    assert_equal 2, invs[0].pipeline_length

    assert_equal ["Stop-Process", "-Force"], invs[1].argv
    assert_equal 1, invs[1].position_in_pipeline
    assert_equal 2, invs[1].pipeline_length
  end

  def test_parse_redirection
    invs, warns = Parser.parse("dir > out.txt")
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["dir"], invs[0].argv
    assert_equal 1, invs[0].redirects.size
    assert_equal ">", invs[0].redirects[0].operator
    assert_equal "out.txt", invs[0].redirects[0].target
    assert invs[0].redirects[0].affects_classification
  end

  def test_parse_script_block
    invs, warns = Parser.parse("& { Get-ChildItem; Stop-Process -Name calc }")
    assert_empty warns
    # Outer command '&' with script block, and nested commands inside
    cmds = invs.map(&:argv)
    assert(cmds.any? { |c| c.include?("Get-ChildItem") })
    assert(cmds.any? { |c| c.include?("Stop-Process") })
  end

  def test_parse_multiple_statements
    invs, warns = Parser.parse("cat test.txt; ls -la")
    assert_empty warns
    assert_equal 2, invs.size
    assert_equal ["cat", "test.txt"], invs[0].argv
    assert_equal ["ls", "-la"], invs[1].argv
  end
end
