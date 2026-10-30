require "test_helper"

class ConfigTest < Minitest::Test
  def test_defaults_without_file
    c = Oops::Config.load("/nonexistent/config.yml")
    assert_equal({}, c.replace)
    assert_equal [], c.secrets
    assert_equal "auto", c.clipboard
    assert_equal [], c.warnings
  end

  def test_loads_and_sorts_replace_longest_first
    Dir.mktmpdir do |d|
      File.write("#{d}/c.yml", "replace:\n  ab: x\n  abcd: y\nsecrets:\n  - 'sk_\\w+'\nclipboard: pbcopy\nbogus: 1\n")
      c = Oops::Config.load("#{d}/c.yml")
      assert_equal %w[abcd ab], c.replace.keys
      assert_equal [/sk_\w+/], c.secrets
      assert_equal "pbcopy", c.clipboard
      assert_equal ["unknown key: bogus"], c.warnings
    end
  end

  def test_broken_yaml_warns_and_uses_defaults
    Dir.mktmpdir do |d|
      File.write("#{d}/c.yml", "replace: [unclosed")
      c = Oops::Config.load("#{d}/c.yml")
      assert_equal({}, c.replace)
      assert_match(/could not parse/, c.warnings.first)
    end
  end

  def test_invalid_regex_warns_and_is_skipped
    Dir.mktmpdir do |d|
      File.write("#{d}/c.yml", "secrets:\n  - '(unclosed'\n  - 'ok\\d'\n")
      c = Oops::Config.load("#{d}/c.yml")
      assert_equal [/ok\d/], c.secrets
      assert_equal 1, c.warnings.size
      assert_match(/invalid secret pattern/, c.warnings.first)
    end
  end

  def test_blank_secret_is_skipped_with_warning
    Dir.mktmpdir do |d|
      File.write("#{d}/c.yml", "secrets:\n  - ''\n  - \n  - 'ok'\nclipboard: ''\n")
      c = Oops::Config.load("#{d}/c.yml")
      assert_equal [/ok/], c.secrets
      assert_equal 2, c.warnings.size
      assert_equal "auto", c.clipboard
    end
  end

  def test_wrong_types_warn_and_are_ignored
    Dir.mktmpdir do |d|
      File.write("#{d}/c.yml", "replace: [a, b]\nsecrets: nope\n")
      c = Oops::Config.load("#{d}/c.yml")
      assert_equal({}, c.replace)
      assert_equal [], c.secrets
      assert_equal 2, c.warnings.size
    end
  end

  def test_replace_is_mutable
    c = Oops::Config.load("/nonexistent/config.yml")
    c.replace["a"] = "b"
    assert_equal({ "a" => "b" }, c.replace)
  end

  def test_boolean_clipboard_means_auto
    Dir.mktmpdir do |d|
      path = File.join(d, "c.yml")
      { "true" => "auto", "false" => "auto", "\"true\"" => "auto", "xsel" => "xsel" }.each do |yaml, want|
        File.write(path, "clipboard: #{yaml}\n")
        assert_equal want, Oops::Config.new(path).clipboard, yaml
      end
    end
  end

  def test_nil_path_uses_xdg_config_home
    Dir.mktmpdir do |d|
      FileUtils.mkdir_p("#{d}/oops")
      File.write("#{d}/oops/config.yml", "clipboard: xclip\n")
      assert_equal "xclip", Oops::Config.load(nil, env: { "XDG_CONFIG_HOME" => d }).clipboard
    end
  end
end

class PathsTest < Minitest::Test
  def test_xdg_and_fallbacks
    assert_equal "/c/oops/config.yml", Oops::Paths.config_file(env: { "XDG_CONFIG_HOME" => "/c" })
    assert_equal "/s/oops/sessions", Oops::Paths.sessions_dir(env: { "XDG_STATE_HOME" => "/s" })
    assert_equal File.join(Dir.home, ".config/oops/config.yml"), Oops::Paths.config_file(env: {})
    assert_equal File.join(Dir.home, ".local/state/oops/sessions"), Oops::Paths.sessions_dir(env: {})
    empty = { "XDG_CONFIG_HOME" => "" }
    assert_equal File.join(Dir.home, ".config/oops/config.yml"), Oops::Paths.config_file(env: empty)
  end

  def test_ensure_sessions_dir_creates_private_dir
    Dir.mktmpdir do |d|
      dir = Oops::Paths.ensure_sessions_dir!(env: { "XDG_STATE_HOME" => d })
      assert_equal "#{d}/oops/sessions", dir
      assert_equal 0o700, File.stat(dir).mode & 0o777
    end
  end

  def test_ensure_sessions_dir_tightens_existing_perms
    Dir.mktmpdir do |d|
      FileUtils.mkdir_p("#{d}/oops/sessions", mode: 0o755)
      File.chmod(0o755, "#{d}/oops/sessions")
      dir = Oops::Paths.ensure_sessions_dir!(env: { "XDG_STATE_HOME" => d })
      assert_equal 0o700, File.stat(dir).mode & 0o777
    end
  end
end
