require "test_helper"
require "pty"
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

class CLICopyTest < Minitest::Test
  NOT_RECORDING_ZSH = "oops: not recording in this shell. Add  eval \"$(oops init zsh)\"  " \
                      "to ~/.zshrc (after whatever puts oops's Ruby on PATH, as early as possible) " \
                      "and open a new tab.\n".freeze
  NOT_RECORDING_BASH = "oops: not recording in this shell. Add  eval \"$(oops init bash)\"  " \
                       "to ~/.bashrc (after whatever puts oops's Ruby on PATH, as early as possible) " \
                       "and open a new tab.\n".freeze

  def setup
    @dir = Dir.mktmpdir
    @clip = File.join(@dir, "clip")
    @session = File.join(@dir, "session.jsonl")
    File.write(@session, "")
    @log = Oops::SessionLog.new(@session)
    FileUtils.mkdir_p(File.join(@dir, "cfg", "oops"))
    write_config("clipboard: \"cat > #{@clip}\"\n")
    @env = { "OOPS_SESSION" => @session, "XDG_CONFIG_HOME" => File.join(@dir, "cfg"),
             "HOME" => @dir, "SHELL" => "/bin/zsh" }
    @seq = 0
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_config(text)
    File.write(File.join(@dir, "cfg", "oops", "config.yml"), text)
  end

  def add(cmd, output, exit: 0)
    @seq += 1
    @log.append(Oops::Record.new(seq: @seq, cmd: cmd, cwd: @dir, started_at: 1, ended_at: 2, exit: exit,
                                 output: output, dropped_bytes: 0, fullscreen: false))
  end

  def run_cli(*argv, env: @env)
    out = StringIO.new
    err = StringIO.new
    status = Oops::CLI.run(argv, env: env, stdout: out, stderr: err)
    [status, out.string, err.string]
  end

  def clip = File.read(@clip)

  # What was written to the slave side of a pty, as the master reads it.
  def read_available(master)
    master.wait_readable(2)
    master.read_nonblock(4096)
  end

  def test_not_recording_message_exits_one
    assert_equal [1, "", NOT_RECORDING_ZSH], run_cli(env: @env.merge("OOPS_SESSION" => nil))
    assert_equal [1, "", NOT_RECORDING_ZSH], run_cli(env: @env.merge("OOPS_SESSION" => ""))
    refute File.exist?(@clip)
  end

  def test_not_recording_when_session_file_is_missing
    File.delete(@session)
    assert_equal [1, "", NOT_RECORDING_ZSH], run_cli
  end

  def test_not_recording_message_names_bash_for_bash_users
    env = @env.merge("OOPS_SESSION" => nil, "SHELL" => "/usr/local/bin/bash")
    assert_equal [1, "", NOT_RECORDING_BASH], run_cli("err", env: env)
  end

  def test_copies_last_and_reports
    add("c1", "one\r\n")
    add("c2", "two\r\n")
    assert_equal [0, "copied: $ c2 (1 lines)\n", ""], run_cli
    assert_equal "```\n$ c2\ntwo\n```\n", clip
  end

  def test_skips_oops_itself_and_unfinished_records
    add("make", "built\r\n")
    add("oops", "copied: $ make (1 lines)\r\n")
    add("sleep 9", "", exit: nil)
    assert_equal 0, run_cli.first
    assert_equal "```\n$ make\nbuilt\n```\n", clip
  end

  def test_n_and_err_and_github_flag
    add("bad", "boom\r\n", exit: 2)
    add("good", "fine\r\n")
    assert_equal [0, "copied: $ bad (2 lines)\n", ""], run_cli("2")
    assert_equal "```\n$ bad\nboom\n(exit 2)\n\n$ good\nfine\n```\n", clip
    assert_equal [0, "copied: $ bad (1 lines)\n", ""], run_cli("err")
    assert_equal "```\n$ bad\nboom\n(exit 2)\n```\n", clip
    assert_equal 0, run_cli("--github").first
    assert_equal "```console\n$ good\nfine\n```\n", clip
    assert_equal 0, run_cli("err", "--github").first
    assert_equal "```console\n$ bad\nboom\n(exit 2)\n```\n", clip
  end

  def test_n_larger_than_history_copies_what_there_is
    add("only", "x\r\n")
    assert_equal [0, "copied: $ only (1 lines)\n", ""], run_cli("5")
  end

  def test_tail_head_and_show_secrets_options
    add("seq 5", "1\r\n2\r\n3\r\n4\r\n5\r\n")
    assert_equal [0, "copied: $ seq 5 (1 lines)\n", ""], run_cli("--tail", "1")
    assert_equal "```\n$ seq 5\n... 4 lines omitted ...\n5\n```\n", clip
    assert_equal 0, run_cli("--head=1", "--tail=1").first
    assert_equal "```\n$ seq 5\n1\n... 3 lines omitted ...\n5\n```\n", clip
    add("echo t", "ghp_#{'a' * 36}\r\n")
    assert_equal [0, "copied: $ echo t (1 lines)\n", ""], run_cli("--show-secrets")
    assert_equal "```\n$ echo t\nghp_#{'a' * 36}\n```\n", clip
  end

  def test_paused_message
    add("c1", "one\r\n")
    @log.pause!
    assert_equal [1, "", "oops: recording is paused. Run  oops resume  first.\n"], run_cli
    assert_equal 1, run_cli("err").first
    refute File.exist?(@clip)
  end

  def test_no_command_found_message
    assert_equal [1, "", "oops: no command found yet.\n"], run_cli
    add("oops", "x\r\n")
    assert_equal [1, "", "oops: no command found yet.\n"], run_cli("3")
  end

  def test_no_failed_command_message
    add("ok", "fine\r\n")
    assert_equal [1, "", "oops: no failed command found.\n"], run_cli("err")
    refute File.exist?(@clip)
  end

  def test_secrets_count_in_report
    add("echo $T", "ghp_#{'a' * 36}\r\n")
    assert_equal [0, "copied: $ echo $T (1 lines, 1 secrets masked)\n", ""], run_cli
    assert_equal "```\n$ echo $T\n[secret]\n```\n", clip
  end

  def test_report_masks_and_replaces_the_command
    write_config("clipboard: \"cat > #{@clip}\"\nreplace:\n  acme: example\n")
    add("curl https://u:pw@acme.test", "ok\r\n")
    assert_equal [0, "copied: $ curl https://[secret]@example.test (1 lines, 1 secrets masked)\n", ""], run_cli
  end

  def test_report_shows_only_the_first_line_of_a_multiline_command
    add("for i in 1 2\ndo echo $i\ndone", "1\r\n2\r\n")
    assert_equal [0, "copied: $ for i in 1 2 ... (2 lines)\n", ""], run_cli
    assert_equal "```\n$ for i in 1 2\n  do echo $i\n  done\n1\n2\n```\n", clip
  end

  def test_config_warnings_go_to_stderr
    write_config("clipboard: \"cat > #{@clip}\"\nbogus: 1\nsecrets: nope\n")
    add("c1", "one\r\n")
    status, out, err = run_cli
    assert_equal 0, status
    assert_equal "copied: $ c1 (1 lines)\n", out
    assert_equal "oops: warning: unknown key: bogus\noops: warning: secrets must be a list; ignored\n", err
  end

  def test_clipboard_failure_exits_one
    write_config("clipboard: \"echo nope >&2; exit 3\"\n")
    add("c1", "one\r\n")
    status, out, err = run_cli
    assert_equal 1, status
    assert_empty out
    assert_equal "oops: echo failed (exit 3): nope\n", err
  end

  def test_no_clipboard_tool_message
    add("c1", "one\r\n")
    with_detect(->(*, **) {}) do
      assert_equal [1, "", "oops: no clipboard tool found (tried pbcopy, wl-copy, xclip, xsel, clip.exe, OSC 52).\n"],
                   run_cli
    end
  end

  def test_clipboard_true_or_false_in_config_means_auto_detect
    add("c1", "one\r\n")
    seen = []
    fake = Object.new
    def fake.copy(_text) = nil
    %w[false true].each do |value|
      write_config("clipboard: #{value}\n")
      with_detect(->(setting, **) { (seen << setting) && fake }) { assert_equal 0, run_cli.first }
    end
    assert_equal %w[auto auto], seen
    assert_equal "osc52", Oops::Clipboard.detect("false", env: {}, which: ->(_) { false }).name
  end

  def test_bad_counts_exit_two
    add("c1", "one\r\n")
    assert_equal [2, "", "oops: N must be a positive integer\n"], run_cli("0")
    assert_equal [2, "", "oops: N must be a positive integer\n"], run_cli("2x")
    assert_equal [2, "", "oops: --tail must be a positive integer\n"], run_cli("--tail", "0")
    assert_equal [2, "", "oops: --tail must be a positive integer\n"], run_cli("--tail=abc")
    assert_equal [2, "", "oops: --head must be a positive integer\n"], run_cli("err", "--head", "-3")
    refute File.exist?(@clip)
  end

  def test_unknown_command_and_extra_arguments_exit_two
    assert_equal [2, "", "oops: unknown command: frobnicate\n"], run_cli("frobnicate")
    assert_equal [2, "", "oops: unexpected argument: err\n"], run_cli("3", "err")
    status, _, err = run_cli("--tail")
    assert_equal 2, status
    assert_match(/\Aoops: missing argument: --tail/, err)
  end

  def test_pause_writes_marker_and_flag
    assert_equal [0, Oops::Marker.pause, ""], run_cli("pause")
    assert_predicate @log, :paused?
    assert_equal [0, Oops::Marker.resume, ""], run_cli("resume")
    refute_predicate @log, :paused?
  end

  def test_pause_flag_exists_before_the_marker_is_written
    seen = []
    flag = "#{@session}.paused"
    out = StringIO.new
    out.define_singleton_method(:write) do |*args|
      seen << File.exist?(flag)
      super(*args)
    end
    Oops::CLI.run(["pause"], env: @env, stdout: out, stderr: StringIO.new)
    Oops::CLI.run(["resume"], env: @env, stdout: out, stderr: StringIO.new)
    assert_equal [true, false], seen
  end

  # With stdout redirected (`oops pause >/dev/null`) the marker would never
  # reach the recorder, while the flag file already says "paused".
  def test_pause_marker_goes_to_the_recorded_terminal_not_stdout
    master, slave = PTY.open
    env = @env.merge("OOPS_TTY" => slave.path)
    assert_equal [0, "", ""], run_cli("pause", env: env)
    assert_equal Oops::Marker.pause, read_available(master)
    assert_equal [0, "", ""], run_cli("resume", env: env)
    assert_equal Oops::Marker.resume, read_available(master)
  ensure
    master&.close
    slave&.close
  end

  def test_pause_marker_falls_back_to_stdout_when_the_terminal_cannot_be_opened
    env = @env.merge("OOPS_TTY" => File.join(@dir, "no", "such", "tty"))
    assert_equal [0, Oops::Marker.pause, ""], run_cli("pause", env: env)
    assert_predicate @log, :paused?
  end

  def test_pause_and_resume_require_recording
    env = @env.merge("OOPS_SESSION" => nil)
    assert_equal [1, "", NOT_RECORDING_ZSH], run_cli("pause", env: env)
    assert_equal [1, "", NOT_RECORDING_ZSH], run_cli("resume", env: env)
  end

  def test_pause_rejects_arguments
    assert_equal [2, "", "oops: usage: oops pause\n"], run_cli("pause", "now")
    refute_predicate @log, :paused?
  end

  private

  def with_detect(replacement)
    singleton = Oops::Clipboard.singleton_class
    singleton.alias_method(:__orig_detect, :detect)
    singleton.define_method(:detect, &replacement)
    yield
  ensure
    singleton.remove_method(:detect)
    singleton.alias_method(:detect, :__orig_detect)
    singleton.remove_method(:__orig_detect)
  end
end
