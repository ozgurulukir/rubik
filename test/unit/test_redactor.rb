# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/redactor"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/ui/diff_viewer"

class TestRedactor < Minitest::Test
  def test_redacts_api_keys
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("sk-1234567890abcdef1234567890")
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("sk-ant-1234567890abcdef1234567890")
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("AKIA1234567890ABCDEF")
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("ghp_1234567890abcdefghijklmnopqrstuvwxyz")
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("github_pat_11AAAAAAA00000000000000_1234567890abcdefghijklmnopqrstuvwxyz")
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("AIzaSy0123456789abcdefghijklmnopqrstuvw")
  end

  def test_redacts_bearer_tokens
    assert_equal "***MASKED***", Rubik::Security::Redactor.redact("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
    # Short prose is not masked
    assert_equal "the bearer of bad news", Rubik::Security::Redactor.redact("the bearer of bad news")
  end

  def test_redacts_private_keys
    pem = <<~KEY
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA0Y123456789...
      -----END RSA PRIVATE KEY-----
    KEY
    assert_equal "***MASKED***\n", Rubik::Security::Redactor.redact(pem)
  end

  def test_redacts_basic_auth_urls
    url = "https://user:mysecretpassword@github.com/repo.git"
    assert_equal "https://user:***MASKED***@github.com/repo.git", Rubik::Security::Redactor.redact(url)
  end

  def test_redacts_assignments
    assert_equal "password=***MASKED***", Rubik::Security::Redactor.redact("password=super_secret")
    assert_equal "passwd: ***MASKED***", Rubik::Security::Redactor.redact("passwd: 'super_secret'")
    assert_equal "api_key=***MASKED***", Rubik::Security::Redactor.redact("api_key=\"secret_key\"")
    assert_equal "secret=***MASKED***", Rubik::Security::Redactor.redact("secret=my_secret")
    assert_equal "token=***MASKED***", Rubik::Security::Redactor.redact("token=secret_token_val")
  end

  def test_does_not_mask_token_counts_or_integers
    assert_equal "max_tokens: 100", Rubik::Security::Redactor.redact("max_tokens: 100")
    assert_equal "token_count = 50", Rubik::Security::Redactor.redact("token_count = 50")
    assert_equal "token: 20", Rubik::Security::Redactor.redact("token: 20")
    assert_equal "tokens = 10", Rubik::Security::Redactor.redact("tokens = 10")
  end

  def test_guard_mask_text_delegates_to_redactor
    guard = Rubik::Security::Guard.new(audit_log_path: nil)
    assert_equal "***MASKED***", guard.mask_text("sk-ant-1234567890abcdef1234567890")
    assert_equal "password=***MASKED***", guard.mask_text("password=foobar")
  end

  def test_diff_viewer_redaction
    mock_shell = Struct.new(:output, :input).new(StringIO.new, StringIO.new)
    theme = Rubik::UI::Theme.new(enabled: false)
    diff = "+password=super_secret_value\n"
    Rubik::UI::DiffViewer.render(mock_shell, theme, diff)
    assert_includes mock_shell.output.string, "+password=***MASKED***"
    refute_includes mock_shell.output.string, "super_secret_value"
  end
end
