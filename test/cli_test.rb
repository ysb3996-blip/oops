require "test_helper"
class CLITest < Minitest::Test
  def test_version_prints_version_and_exits_zero
    out = StringIO.new
    status = Oops::CLI.run(["--version"], stdout: out, stderr: StringIO.new)
    assert_equal 0, status
    assert_equal "oops #{Oops::VERSION}\n", out.string
  end

  def test_unknown_option_exits_two
    err = StringIO.new
    status = Oops::CLI.run(["--bogus"], stdout: StringIO.new, stderr: err)
    assert_equal 2, status
    assert_match(/oops: /, err.string)
  end

  def test_init_prints_snippet_with_absolute_bin
    out = StringIO.new
    status = Oops::CLI.run(%w[init zsh], stdout: out, stderr: StringIO.new)
    assert_equal 0, status
    assert_equal Oops::ShellInit.snippet("zsh", bin: File.expand_path($PROGRAM_NAME)), out.string
    assert_includes out.string, "__oops_bin='#{File.expand_path($PROGRAM_NAME)}'"
  end

  def test_init_bash
    out = StringIO.new
    assert_equal 0, Oops::CLI.run(%w[init bash], stdout: out, stderr: StringIO.new)
    assert_includes out.string, "PROMPT_COMMAND"
  end

  def test_init_unsupported_shell_exits_two
    out = StringIO.new
    err = StringIO.new
    status = Oops::CLI.run(%w[init fish], stdout: out, stderr: err)
    assert_equal 2, status
    assert_equal "oops: unsupported shell: fish (supported: zsh, bash)\n", err.string
    assert_empty out.string
  end

  def test_init_without_shell_exits_two
    err = StringIO.new
    assert_equal 2, Oops::CLI.run(%w[init], stdout: StringIO.new, stderr: err)
    assert_match(/oops: usage: oops init/, err.string)
  end
end
