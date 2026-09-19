# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/database"
require_relative "../../lib/rubik/security/classifier/matcher"
require_relative "../../lib/rubik/security/classifier/parsers/bash"

class TestCommandClassifierMatcher < Minitest::Test
  Matcher = Rubik::Security::Classifier::Matcher
  Parser = Rubik::Security::Classifier::Parsers::Bash

  def setup
    @db = Rubik::Security::Classifier::CommandDatabase.new
  end

  def match(expr)
    invs, warns = Parser.parse(expr)
    Matcher.match_command(invs[0], @db, warns)
  end

  def test_matches_git_status_as_readonly
    res = match("git status")
    assert_equal :readonly, res.classification
    assert_equal :low, res.risk
    assert_equal "git.status", res.matched_rule
  end

  def test_strips_global_options_before_subcommand
    res = match("git -C /path status")
    assert_equal :readonly, res.classification
    assert_equal "git.status", res.matched_rule
    assert_equal ["/path"], res.directories
  end

  def test_matches_kubectl_get_pods
    res = match("kubectl get pods -n kube-system")
    assert_equal :readonly, res.classification
    assert_equal :low, res.risk
    assert_equal "kubectl.get", res.matched_rule
  end

  def test_matches_sudo_delegation
    res = match("sudo ls -la /root")
    # sudo has min_classification: DANGEROUS
    assert_equal :dangerous, res.classification
    assert_equal "sudo", res.matched_rule
    assert_equal 1, res.inner_commands.size
    assert_equal ["ls"], res.inner_commands[0].command
  end

  def test_matches_timeout_delegation
    res = match("timeout 5s ls -la /tmp")
    assert_equal :readonly, res.classification
    assert_equal "timeout", res.matched_rule
    assert_equal 1, res.inner_commands.size
    assert_equal ["ls"], res.inner_commands[0].command
  end

  def test_matches_sh_c_delegation
    res = match("sh -c 'git commit -m \"msg\"'")
    assert_equal :local_effects, res.classification
    assert_equal 1, res.inner_commands.size
    assert_equal ["git", "commit"], res.inner_commands[0].command
  end

  def test_matches_find_exec_delegation
    res = match("find . -name '*.rb' -exec ls -l {} \\;")
    assert_equal :readonly, res.classification
    assert_equal 1, res.inner_commands.size
    assert_equal ["ls"], res.inner_commands[0].command
  end

  def test_classification_reason_distinguishes_base_vs_blocked
    res_readonly = match("cat file.txt")
    assert_equal :readonly, res_readonly.classification
    assert_match(/^base rule: cat/, res_readonly.classification_reason)

    res_dangerous = match("bash script.sh")
    assert_equal :dangerous, res_dangerous.classification
    assert_match(/^blocked by default rule: bash/, res_dangerous.classification_reason)
  end
end
