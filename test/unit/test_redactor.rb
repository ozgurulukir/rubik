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

  def test_quick_check_regex_covers_all_secret_patterns
    sample_secrets = [
      "sk-1234567890abcdef1234567890",
      "sk-ant-1234567890abcdef1234567890",
      "AKIA1234567890ABCDEF",
      "ghp_1234567890abcdefghijklmnopqrstuvwxyz",
      "github_pat_11AAAAAAA00000000000000_1234567890abcdefghijklmnopqrstuvwxyz",
      "AIzaSy0123456789abcdefghijklmnopqrstuvw",
      "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
      "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0Y123456789...\n-----END RSA PRIVATE KEY-----",
      "https://user:mysecretpassword@github.com/repo.git",
      "password=super_secret",
      "passwd: 'super_secret'",
      "api_key=\"secret_key\"",
      "secret=my_secret",
      "token=secret_token_val"
    ]

    sample_secrets.each do |sec|
      assert_match Rubik::Security::Redactor::QUICK_CHECK_REGEX, sec, "QUICK_CHECK_REGEX must match #{sec.inspect}"
    end
  end

  def test_returns_duplicated_string_on_clean_input
    input = "A completely clean string with no secrets"
    result = Rubik::Security::Redactor.redact(input)
    assert_equal input, result
    refute_same input, result, "redact must return a duplicated string to prevent caller mutation bugs"
  end

  def test_redact_is_total_on_invalid_utf8
    input = "password=hunter2 \xFF raw tool output"
    refute_predicate input, :valid_encoding?
    result = Rubik::Security::Redactor.redact(input)
    assert_equal "password=***MASKED*** \uFFFD raw tool output", result
    assert_predicate result, :valid_encoding?
  end

  def test_redact_scrubs_clean_invalid_utf8_without_raising
    result = Rubik::Security::Redactor.redact("plain tool output \xFF tail")
    assert_equal "plain tool output \uFFFD tail", result
  end

  def test_redacts_secret_in_binary_string
    input = "password=hunter2 \xDE\xAD\xBE\xEF".b
    result = Rubik::Security::Redactor.redact(input)
    assert_equal "password=***MASKED*** \xDE\xAD\xBE\xEF".b, result
  end

  def test_redact_does_not_mutate_caller_binary_string
    input = "plain stdout \xDE\xAD".b
    result = Rubik::Security::Redactor.redact(input)
    assert_equal input, result
    refute_same input, result
  end
end
