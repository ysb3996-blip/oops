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

  def test_emails_with_subdomains_masked
    ["a.b@sub.example.co.jp", "x+tag@mail.example.com", "me@host.io"].each do |addr|
      assert_equal ["to [secret] now", 1], mask("to #{addr} now")
    end
  end

  def test_versioned_package_names_not_email
    ["/opt/homebrew/opt/mysql@8.4/bin/mysqld_safe", "mise use -g go@1.27", "go@1.27.3", "python@3.12",
     "node@22.1.0-rc", "pkg@1.2.3-beta"].each { |text| assert_equal [text, 0], mask(text) }
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

  def test_hugging_face_access_tokens_masked
    token = "hf_#{'Ab12' * 6}" # Synthetic; no real credential in source control.
    assert_equal ["[secret]", 1], mask(token)
    assert_equal ["model [secret] loaded", 1], mask("model #{token} loaded")
  end

  def test_supabase_secret_keys_masked
    token = "sb_secret_#{'Ab3_' * 8}" # Synthetic, never an issued key.
    assert_equal ["[secret]", 1], mask(token)
    assert_equal ["Supabase [secret] ready", 1], mask("Supabase #{token} ready")
    assert_equal ["[secret]", 1], mask("sb_\"secret_#{'Ab3_' * 8}\"")
  end

  def test_supabase_key_near_misses_kept
    token = "sb_secret_#{'Ab3_' * 8}"
    public_key = "sb_publishable_#{'Ab3_' * 8}"
    [
      public_key, "Supabase supports sb_secret_ keys", "sb_secret_#{'A' * 23}",
      "sb_secret_#{'A' * 129}", "prefix_#{token}",
      "sb_secret_#{'A' * 150_000}"
    ].each do |text|
      assert_equal [text, 0], mask(text), text[0, 90]
    end
  end

  def test_hugging_face_token_near_misses_kept
    token = "hf_#{'Ab12' * 6}"
    ["hf_#{'A' * 15}", "not#{token}", "prefix_#{token}",
     "#{token}_suffix", "hf-model-download"].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_linear_personal_api_keys_masked
    token = "lin_api_#{'Ab12' * 10}"
    assert_equal ["[secret]", 1], mask(token)
    assert_equal ["Linear [secret] ready", 1], mask("Linear #{token} ready")
  end

  def test_linear_personal_api_key_near_misses_kept
    token = "lin_api_#{'Ab12' * 10}"
    ["lin_api_#{'A' * 39}", "lin_api_#{'A' * 41}",
     "pre#{token}", "#{token}_suffix", "lin_api_example"].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_notion_integration_tokens_masked
    token = "ntn_#{'1' * 11}#{'aB3' * 11}xy"
    assert_equal ["[secret]", 1], mask(token)
    assert_equal ["notion [secret] saved", 1], mask("notion #{token} saved")
    assert_equal ["[secret]-backup", 1], mask("#{token}-backup")
  end

  def test_notion_token_near_misses_kept
    token = "ntn_#{'1' * 11}#{'aB3' * 11}xy"
    ["ntn_#{'A' * 39}", "ntn_example_token", "ntn_integration_token_value",
     "not#{token}", "prefix_#{token}", "#{token}_suffix"].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_digitalocean_api_tokens_masked
    %w[dop doo dor].each do |kind|
      token = "#{kind}_v1_#{'a1b2c3d4' * 8}"
      assert_equal ["[secret]", 1], mask(token)
      assert_equal ["credential [secret] set", 1], mask("credential #{token} set")
    end
  end

  def test_digitalocean_token_near_misses_kept
    token = "dop_v1_#{'a1b2c3d4' * 8}"
    ["dop_v1_#{'a' * 63}", "doo_v1_#{'b' * 65}",
     "dor_v2_#{'c' * 64}", "dop_v1_#{'g' * 64}",
     "not#{token}", "#{token}_suffix"].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_shopify_access_tokens_masked
    %w[shpat shpca shppa].each do |prefix|
      token = "#{prefix}_#{'Ab12' * 8}"
      assert_equal ["[secret]", 1], mask(token)
      assert_equal ["credential [secret] saved", 1], mask("credential #{token} saved")
    end
  end

  def test_shopify_access_token_near_misses_kept
    token = "shpat_#{'Ab12' * 8}"
    ["shpat_#{'a' * 31}", "shpat_#{'a' * 31}_", "shpat_#{'a' * 31}-",
     "not#{token}", "prefix_#{token}", "#{token}_suffix", "shpxx_#{'a' * 32}"].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_sentry_organization_tokens_masked
    payload = "eyJpYXQiOi#{'A1b2' * 12}=="
    secret = "#{'aB3/' * 10}x+y"
    token = "sntrys_#{payload}_#{secret}"
    assert_equal ["[secret]", 1], mask(token)
    assert_equal ["credential [secret] saved", 1], mask("credential #{token} saved")
    assert_equal ["[secret]-", 1], mask("#{token}-")
    assert_equal ["[secret]", 1], mask("sntrys_eyJ#{'a' * 800}_#{secret}")
  end

  def test_sentry_organization_token_near_misses_kept
    payload = "eyJpYXQiOi#{'A1b2' * 12}=="
    secret = "x" * 43
    token = "sntrys_#{payload}_#{secret}"
    ["sntrys_#{payload}_#{'x' * 42}", "sntrys_#{payload}_#{'x' * 44}",
     "sntrys_eyJabcd_#{secret}", "sntrys_eyJ#{'a' * 801}_#{secret}",
     "not#{token}", "prefix_#{token}", "#{token}_suffix", "#{token}/suffix", "sntryu_#{secret}"].each do |text|
      assert_equal [text, 0], mask(text)
    end
  end

  def test_sendgrid_api_keys_masked
    token = "SG.#{'Ab1_' * 5}Q-." + "#{'Cd4-' * 10}x_7"
    assert_equal ["[secret]", 1], mask(token)
    assert_equal ["sendgrid [secret] here", 1], mask("sendgrid #{token} here")
  end

  def test_sendgrid_api_key_near_misses_kept
    prefix = "SG.#{'A' * 22}."
    token = prefix + ("B" * 43)
    ["SG.#{'A' * 21}.#{'B' * 43}", prefix + ("B" * 42),
     prefix + ("B" * 44), "not#{token}", "#{token}_suffix"].each do |text|
      assert_equal [text, 0], mask(text)
    end
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
     "docker login " * 20_000, "a" * 200_000,
     "a@1." * 50_000, "a.b@" * 50_000].each do |text|
      assert_operator elapsed { mask(text) }, :<, 2.0
    end
  end

  # The shell removes the quotes before the command runs, so the output holds
  # the token in one piece while the recorded command line does not.
  def test_tokens_split_by_shell_quotes_masked
    token = "ghp_#{'a' * 36}"
    assert_equal ["echo [secret]", 1], mask(%(echo ghp_"#{'a' * 36}"))
    assert_equal ["echo [secret]", 1], mask("echo ghp_'#{'a' * 36}'")
    assert_equal ["echo [secret]", 1], mask("echo ghp_\\#{'a' * 36}")
    assert_equal ["GH_TOKEN=[secret] gh auth status", 1], mask(%(GH_TOKEN=gh"p_#{'a' * 36}" gh auth status))
    assert_equal ["curl -d [secret] x", 1], mask(%(curl -d "#{token[0, 10]}""#{token[10..]}" x))
  end

  def test_split_token_keeps_the_assignment_and_trailing_operators
    supabase = %(sb_"secret_#{'Ab3_' * 8}")
    assert_equal ["export K=[secret]; echo ok", 1], mask(%(export K=#{supabase}; echo ok))
    assert_equal ["gh --token=[secret] x", 1], mask(%(gh --token=gh"p_#{'a' * 36}" x))
    assert_equal ["a [secret]&& b", 1], mask(%(a ghp_"#{'a' * 36}"&& b))
    assert_equal ["$(echo [secret])", 1], mask(%($(echo ghp_"#{'a' * 36}")))
  end

  # The part before = belongs to the token here, so nothing of the word is kept.
  def test_split_token_reaching_into_the_assignment_masks_the_whole_word
    assert_equal ["[secret]", 1], mask(%(sntrys_eyJ#{'A' * 16}=_"#{'B' * 43}"))
  end

  def test_quoted_words_without_a_split_token_kept
    token = "ghp_#{'a' * 36}"
    assert_equal [%(export T="[secret]"), 1], mask(%(export T="#{token}"))
    assert_equal [%(echo 'ghp_' "short"), 0], mask(%(echo 'ghp_' "short"))
    assert_equal [%(say "it's fine" \\\n), 0], mask(%(say "it's fine" \\\n))
    assert_equal [%(grep -E 'sk-[a-z]+' "#{'x' * 30}"), 0], mask(%(grep -E 'sk-[a-z]+' "#{'x' * 30}"))
  end

  # Guards against quadratic matching; bounds are loose to avoid flakiness.
  def test_long_single_line_inputs_stay_linear
    ['password="', 'token="a" ', '{"api_key": "abc123","name":"x"},', "dop_v1_#{'a' * 63} ",
     "hf_#{'A' * 100_000}",
     "sb_secret_#{'A' * 100_000}",
     "lin_api_#{'A' * 100_000}_suffix",
     "ntn_#{'A' * 100_000}",
     "SG.#{'A' * 22}.#{'B' * 100_000}",
     "shpat_#{'a' * 100_000}_suffix",
     "sntrys_eyJ#{'A' * 100_000}_#{'x' * 43}",
     %(ghp_"#{'a' * 100_000}"), %("'\\#{'a' * 100_000}), %(a" ),
     %(K=ghp_"#{'a' * 100_000}";), %(a"#{';' * 100_000}b)].each do |unit|
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
