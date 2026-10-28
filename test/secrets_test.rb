# frozen_string_literal: true

require "test_helper"

class SecretsTest < Minitest::Test
  def mask(text) = Oops::Secrets.mask(text)

  def test_aws_access_key     = assert_equal ["key=[secret]", 1], mask("key=AKIAIOSFODNN7EXAMPLE")
  def test_github_token       = assert_equal ["[secret]", 1], mask("ghp_#{'a' * 36}")
  def test_slack_token        = assert_equal ["[secret]", 1], mask("xoxb-1234-abcd")
  def test_jwt                = assert_equal ["[secret]", 1], mask("eyJhbGciOi.eyJzdWIi.SflKxwRJ")

  def test_bearer_header
    assert_equal ["Authorization: Bearer [secret]", 1], mask("Authorization: Bearer abc.def")
  end

  def test_basic_header
    assert_equal ["Authorization: Basic [secret]", 1], mask("Authorization: Basic dXNlcjpwYXNz")
  end

  def test_private_key_block
    key = "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"
    assert_equal ["[secret]", 1], mask(key)
  end

  def test_key_value_pairs
    assert_equal ["API_TOKEN=[secret] password: [secret]", 2], mask("API_TOKEN=abc123 password: hunter2")
  end

  def test_aws_secret_access_key_value
    input = "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    assert_equal ["aws_secret_access_key = [secret]", 1], mask(input)
  end

  def test_mixed_case_name = assert_equal ["Password=[secret]", 1], mask("Password=Hunter2")

  def test_email               = assert_equal ["mail [secret] sent", 1], mask("mail ysb@example.com sent")
  def test_url_userinfo        = assert_equal ["https://[secret]@h.io/x", 1], mask("https://u:p@h.io/x")
  def test_public_ipv4_masked  = assert_equal ["[secret]", 1], mask("8.8.8.8")

  def test_private_ipv4_kept
    %w[127.0.0.1 0.0.0.0 10.1.2.3 192.168.0.1 172.16.0.1 172.31.255.255].each { |ip| assert_equal [ip, 0], mask(ip) }
  end

  def test_version_strings_not_ips
    ["1.2.3.4.5", "v10.1.2.3", "ruby 3.2.1.4.5"].each { |v| assert_equal [v, 0], mask(v) }
  end

  def test_extra_pattern = assert_equal ["[secret]", 1], Oops::Secrets.mask("sk_live_abc", extra: [/sk_live_\w+/])
  def test_count_zero_when_clean = assert_equal ["hello", 0], mask("hello")

  def test_invalid_utf8_does_not_raise
    text, count = mask("token=abc \xFF\xFE ok")
    assert_equal 1, count
    assert_includes text, "token=[secret]"
  end
end
