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
end
