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

  # Delegated inner results must carry their own evidence: the option that
  # overrode the classification (blocked-command guidance renders it) and,
  # when a delegation floor (sudo) forces the severity, the floor itself.
  def test_inner_command_carries_option_override_reason
    res = match('bash -c "git merge --abort"')
    inner = res.inner_commands[0]
    assert_equal :dangerous, inner.classification
    assert_equal "git.merge", inner.matched_rule
    assert_equal "--abort", inner.overriding_option
    assert_equal "overridden by option --abort to dangerous", inner.classification_reason
  end

  def test_inner_command_carries_delegation_floor_reason
    res = match("sudo ls")
    inner = res.inner_commands[0]
    assert_equal :dangerous, inner.classification
    # The floor APPENDS to the inner's own evidence, it must not erase it.
    assert_includes inner.classification_reason, "elevated by delegation floor to dangerous"
    assert_includes inner.classification_reason, "ls"
  end
end

# ── Issue #55 field report: guard-policy parity ──────────────────────────

# 1.1: `git push --delete` is the same ref deletion as the refspec form
# (`git push origin :branch`, EXTERNAL_EFFECTS) and the broader
# `gh api -X DELETE` (EXTERNAL_EFFECTS) — the flag form must not rate
# stricter than both. Force pushes stay DANGEROUS.
def test_git_push_delete_matches_refspec_and_gh_api_severity
  assert_equal :external_effects, match("git push --delete origin feature-x").classification
  assert_equal :external_effects, match("git push origin :feature-x").classification
  assert_equal :external_effects, match("gh api -X DELETE repos/o/r/git/refs/heads/feature-x").classification
  assert_equal :dangerous, match("git push --force origin main").classification
end

# 1.2: the modern `git merge-tree --write-tree` conflict probe (object
# database only, no worktree/index/refs mutation) must classify like the
# legacy form instead of falling through to the strict top-level git rule.
def test_git_merge_tree_write_tree_is_readonly
  res = match("git merge-tree --write-tree --name-only A B")
  assert_equal :readonly, res.classification
  assert_equal :low, res.risk
  assert_equal "git.merge-tree", res.matched_rule
  assert_equal :readonly, match("git merge-tree A B").classification
end

# 1.3: `node --test` is the built-in test runner — the same trust level as
# `npm test`, which shells out to it. Appending --test must NOT launder an
# evaluator (`-e`/`-p`/`-i`): overrides merge by max severity.
def test_node_test_matches_npm_test_severity_and_cannot_launder_evaluators
  assert_equal :local_effects, match("node --test").classification
  assert_equal :medium, match("node --test").risk
  assert_equal :local_effects, match("npm test").classification
  assert_equal :dangerous, match('node -e "evil()" --test').classification
  assert_equal :dangerous, match("node script.js").classification
  assert_equal :dangerous, match("node").classification
end
