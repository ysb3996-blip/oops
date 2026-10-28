require "test_helper"

class ShellInitTest < Minitest::Test
  def test_zsh_snippet_mentions_guards_and_marker_prefix
    s = Oops::ShellInit.snippet("zsh")
    %w[OOPS_TTY OOPS_DISABLE ZSH_ARGZERO add-zsh-hook preexec precmd].each { |w| assert_includes s, w }
    assert_includes s, "\\033_oops;start;"
  end

  def test_bash_snippet_is_bash32_safe
    s = Oops::ShellInit.snippet("bash")
    ["PROMPT_COMMAND", "DEBUG", "login_shell", "history 1"].each { |w| assert_includes s, w }
    refute_match(/\$\{[^}]*,,|\[\[ .* =~ .*\(\?|declare -A|mapfile|\$EPOCHSECONDS/, s)
  end

  def test_unknown_shell_raises = assert_raises(ArgumentError) { Oops::ShellInit.snippet("fish") }

  def test_snippets_parse
    Dir.mktmpdir do |d|
      File.write("#{d}/z", Oops::ShellInit.snippet("zsh"))
      assert system("zsh", "-n", "#{d}/z") if system("which zsh >/dev/null")
      File.write("#{d}/b", Oops::ShellInit.snippet("bash"))
      assert system("bash", "-n", "#{d}/b")
    end
  end

  def test_bin_is_embedded_as_one_quoted_word
    bin = "/opt/it's a dir/oops"
    %w[zsh bash].each do |shell|
      s = Oops::ShellInit.snippet(shell, bin: bin)
      refute_includes s, "__OOPS_BIN__"
      line = s[/^\s*__oops_bin=.*$/]
      out = IO.popen([shell, "-c", "#{line}; printf %s \"$__oops_bin\""], &:read)
      assert_equal bin, out, shell
    end
  end

  def test_snippets_do_nothing_when_not_interactive
    %w[zsh bash].each do |shell|
      next if shell == "zsh" && !system("which zsh >/dev/null")

      out = IO.popen([shell, "-c", "#{Oops::ShellInit.snippet(shell, bin: '/nonexistent/oops')}\necho alive"],
                     err: %i[child out], &:read)
      assert_equal "alive\n", out, shell
    end
  end
end
