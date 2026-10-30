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

  def test_query_string_pairs_each_masked
    assert_equal ["secret=[secret]&token=[secret]", 2], mask("secret=a&token=b")
    assert_equal ["?access_token=[secret]&refresh_token=[secret]", 2], mask("?access_token=abc&refresh_token=xyz")
  end

  def test_quoted_values_masked_whole
    assert_equal ['password: "[secret]"', 1], mask('password: "two words"')
    assert_equal ["pass_key='[secret]'", 1], mask("pass_key='a b'")
    assert_equal ['{"api_key": "[secret]"}', 1], mask('{"api_key": "abc123"}')
  end

  def test_git_scp_remote_not_email
    assert_equal ["git clone git@github.com:foo/bar.git", 0], mask("git clone git@github.com:foo/bar.git")
    assert_equal ["to [secret]: hi", 1], mask("to ysb@example.com: hi")
  end

  def test_escaped_quote_inside_quoted_value
    assert_equal ['password="[secret]" x', 1], mask('password="ab\\"cd ef" x')
  end

  def test_unterminated_quote_does_not_leak
    assert_equal ['password="[secret]', 1], mask('password="abc')
  end

  def test_private_key_without_end_line_masked_to_the_end
    assert_equal ["head\n[secret]", 1], mask("head\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn\nAAAAB\n")
  end

  def test_private_key_with_end_line_keeps_text_after_it
    key = "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----\nafter"
    assert_equal ["[secret]\nafter", 1], mask(key)
  end

  def test_provider_tokens_masked
    {
      "sk-proj-#{'a1B2' * 8}" => "[secret]",
      "sk-ant-api03-#{'a1B2' * 8}" => "[secret]",
      "key sk_live_#{'a1B2' * 6}" => "key [secret]",
      "glpat-#{'a1B2' * 5}" => "[secret]",
      "AIza#{'a1B2' * 8}xyz" => "[secret]",
      "npm_#{'a1B2' * 9}" => "[secret]"
    }.each { |input, expected| assert_equal [expected, 1], mask(input), input }
  end

  def test_short_or_embedded_prefixes_are_not_tokens
    %w[sk-1 task-list-item-name-that-is-long-enough npm_run
       ask-me-anything-about-this-long-thing].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_slack_webhook_url
    url = "https://hooks.slack.com/services/T0123ABCD/B0123ABCD/abcdEFGH1234"
    assert_equal ["https://hooks.slack.com/services/[secret]", 1], mask(url)
  end

  def test_authorization_token_scheme
    assert_equal ["Authorization: token [secret]", 1], mask("Authorization: token ghx123abc")
  end

  def test_password_option_with_space_separated_value
    assert_equal ["mycli --password [secret] --host h", 1], mask("mycli --password hunter2 --host h")
    assert_equal ["mycli --password \"[secret]\"", 1], mask("mycli --password \"two words\"")
    assert_equal ["mycli --password --host h", 0], mask("mycli --password --host h")
  end

  def test_curl_user_option
    assert_equal ["curl -u [secret] https://x.io", 1], mask("curl -u alice:hunter2 https://x.io")
    assert_equal ["curl -s --user [secret] x", 1], mask("curl -s --user alice:hunter2 x")
    assert_equal ["ls -u alice:bob", 0], mask("ls -u alice:bob")
  end

  def test_mysql_attached_password_option
    assert_equal ["mysql -u root -p[secret] db", 1], mask("mysql -u root -phunter2 db")
    assert_equal ["mysql -u root -p db", 0], mask("mysql -u root -p db")
  end

  def test_docker_login_password_option
    assert_equal ["docker login -u me -p [secret] r.io", 1], mask("docker login -u me -p hunter2 r.io")
  end

  # Guards against quadratic matching; bounds are loose to avoid flakiness.
  def test_keyword_stuffed_lines_stay_linear
    ["key" * 30_000, "x.pwd." * 5_000, "token_" * 20_000, "curl " * 40_000, "mysql " * 40_000,
     "docker login " * 20_000, "a" * 200_000].each do |text|
      assert_operator elapsed { mask(text) }, :<, 2.0
    end
  end

  # Guards against quadratic matching; bounds are loose to avoid flakiness.
  def test_long_single_line_inputs_stay_linear
    ['password="', 'token="a" ', '{"api_key": "abc123","name":"x"},'].each do |unit|
      small = unit * (500_000 / unit.size)
      big = unit * (2_000_000 / unit.size)
      assert_operator elapsed { mask(small) }, :<, 2.0
      assert_operator elapsed { mask(big) }, :<, 8.0
    end
  end

  private

  def elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
