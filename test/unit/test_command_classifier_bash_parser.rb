# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/parsers/bash"

class TestCommandClassifierBashParser < Minitest::Test
  Parser = Rubik::Security::Classifier::Parsers::Bash

  def test_parse_simple_command
    invs, warns = Parser.parse("ls -la /tmp")
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["ls", "-la", "/tmp"], invs[0].argv
    assert_equal 0, invs[0].position_in_pipeline
    assert_equal 1, invs[0].pipeline_length
  end

  def test_parse_pipeline
    invs, warns = Parser.parse("cat file.txt | grep search | wc -l")
    assert_empty warns
    assert_equal 3, invs.size

    assert_equal ["cat", "file.txt"], invs[0].argv
    assert_equal 0, invs[0].position_in_pipeline
    assert_equal 3, invs[0].pipeline_length

    assert_equal ["grep", "search"], invs[1].argv
    assert_equal 1, invs[1].position_in_pipeline

    assert_equal ["wc", "-l"], invs[2].argv
    assert_equal 2, invs[2].position_in_pipeline
  end

  def test_parse_redirects
    invs, warns = Parser.parse("echo hello > out.txt 2>&1 < in.txt")
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["echo", "hello"], invs[0].argv

    redirects = invs[0].redirects
    assert_equal 3, redirects.size

    out_red = redirects.find { |r| r.target == "out.txt" }
    assert out_red
    assert_equal ">", out_red.operator
    assert out_red.affects_classification

    fd_red = redirects.find { |r| r.operator.include?(">&") }
    assert fd_red
    refute fd_red.affects_classification

    in_red = redirects.find { |r| r.operator == "<" }
    assert in_red
    refute in_red.affects_classification
  end

  def test_parse_nested_substitutions
    invs, warns = Parser.parse("echo $(whoami) `hostname`")
    assert_empty warns
    # Outer command + 2 nested substitutions
    assert_equal 3, invs.size
    assert_equal ["echo", "$(whoami)", "`hostname`"], invs[0].argv
    assert_equal ["whoami"], invs[1].argv
    assert_equal "command_substitution", invs[1].context
    assert_equal ["hostname"], invs[2].argv
  end

  def test_parse_background_command
    invs, warns = Parser.parse("sleep 10 & ls")
    assert_empty warns
    assert_equal 2, invs.size
    assert_equal ["sleep", "10"], invs[0].argv
    assert invs[0].is_background
    refute invs[1].is_background
  end

  def test_parse_quotes_stripping
    invs, warns = Parser.parse('echo "quoted string" \'single quote\' $\'ansi\'')
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["echo", "quoted string", "single quote", "ansi"], invs[0].argv
  end

  def test_parse_test_command
    invs, warns = Parser.parse("[ -f /tmp/file ]")
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["[", "-f", "/tmp/file"], invs[0].argv
  end
end
