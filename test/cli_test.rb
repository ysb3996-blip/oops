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

  def test_help_describes_command_count_option
    out = StringIO.new
    assert_equal 0, Oops::CLI.run(["--help"], stdout: out, stderr: StringIO.new)
    assert_equal "Usage: oops [N | err | pick] [-n N] [options]\n", out.string.lines.first
    assert_includes out.string, "-n N"
  end

  def test_help_lists_status_time_output_only_and_print
    out = StringIO.new
    assert_equal 0, Oops::CLI.run(["--help"], stdout: out, stderr: StringIO.new)
    assert_includes out.string, "oops init <shell> | pause | resume | status | clear [--all] | doctor"
    assert_includes out.string, "--time"
    assert_includes out.string, "--output-only"
    assert_includes out.string, "-p, --print"
    assert_includes out.string, "--json"
    assert_includes out.string, "--gist"
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

  def test_init_fish
    out = StringIO.new
    assert_equal 0, Oops::CLI.run(%w[init fish], stdout: out, stderr: StringIO.new)
    assert_includes out.string, "fish_preexec"
    assert_includes out.string, "set -g __oops_bin '#{File.expand_path($PROGRAM_NAME)}'"
  end

  def test_init_unsupported_shell_exits_two
    out = StringIO.new
    err = StringIO.new
    status = Oops::CLI.run(%w[init tcsh], stdout: out, stderr: err)
    assert_equal 2, status
    assert_equal "oops: unsupported shell: tcsh (supported: zsh, bash, fish)\n", err.string
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
  NOT_RECORDING_FISH = "oops: not recording in this shell. Add  oops init fish | source  " \
                       "to ~/.config/fish/config.fish (after whatever puts oops's Ruby on PATH, " \
                       "as early as possible) and open a new tab.\n".freeze

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

  def run_cli(*argv, env: @env, stdin: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    status = Oops::CLI.run(argv, env: env, stdin: stdin, stdout: out, stderr: err)
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

  def test_not_recording_message_names_fish_for_fish_users
    env = @env.merge("OOPS_SESSION" => nil, "SHELL" => "/opt/homebrew/bin/fish")
    assert_equal [1, "", NOT_RECORDING_FISH], run_cli(env: env)
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

  def test_pick_lists_on_stderr_and_copies_the_chosen_commands_in_order
    add("make", "built\r\n", exit: 2)
    add("oops", "copied\r\n")
    add("ls", "a\r\n")
    add("pwd", "/x\r\n")
    status, out, err = run_cli("pick", stdin: StringIO.new("3 1\n"))
    assert_equal 0, status
    assert_equal "copied: $ make (2 lines)\n", out
    assert_match(/\A1  \$ make  \(exit 2, 1 line, \d\d:\d\d\)\n2  \$ ls    .*\n3  \$ pwd   .*\npick> \n\z/, err)
    assert_equal "```\n$ make\nbuilt\n(exit 2)\n\n$ pwd\n/x\n```\n", clip
  end

  def test_pick_n_lists_that_many_and_print_keeps_stdout_for_the_text
    add("c1", "one\r\n")
    add("c2", "two\r\n")
    add("c3", "three\r\n")
    status, out, err = run_cli("pick", "-n", "2", "--print", stdin: StringIO.new("1"))
    assert_equal 0, status
    assert_equal "```\n$ c2\ntwo\n```\n", out
    assert_equal 2, err.scan(/^\d  \$ /).size
    refute File.exist?(@clip)
  end

  def test_pick_with_a_bad_or_no_answer_copies_nothing
    add("c1", "one\r\n")
    assert_equal 1, run_cli("pick", stdin: StringIO.new("2\n")).first
    assert_equal 1, run_cli("pick", stdin: StringIO.new("")).first
    assert_match(/oops: nothing picked\.\n\z/, run_cli("pick").last)
    refute File.exist?(@clip)
  end

  def test_pick_takes_no_positional_count
    add("c1", "one\r\n")
    assert_equal [2, "", "oops: unexpected argument: 3\n"], run_cli("pick", "3")
  end

  def test_n_larger_than_history_copies_what_there_is
    add("only", "x\r\n")
    assert_equal [0, "copied: $ only (1 lines)\n", ""], run_cli("5")
  end

  def test_short_count_option_matches_positional_count
    add("c1", "one\r\n")
    add("c2", "two\r\n")
    add("c3", "three\r\n")
    expected = run_cli("2")
    expected_clip = clip
    [%w[-n 2], %w[-n2], %w[-n 02]].each do |args|
      assert_equal expected, run_cli(*args), args.inspect
      assert_equal expected_clip, clip
    end
  end

  def test_short_count_option_skips_oops_and_unfinished_records
    add("c1", "one\r\n")
    add("oops -n 2", "copied\r\n")
    add("unfinished", "", exit: nil)
    add("c2", "two\r\n")
    assert_equal [0, "copied: $ c1 (2 lines)\n", ""], run_cli("-n", "2")
    assert_equal "```\n$ c1\none\n\n$ c2\ntwo\n```\n", clip
  end

  def test_short_count_option_combines_with_formatting_options
    add("c1", "one\r\ntwo\r\nthree\r\n")
    add("c2", "four\r\nfive\r\nsix\r\n")
    expected = run_cli("2", "--github", "--output-only")
    expected_clip = clip
    assert_equal 0, expected.first
    assert_equal expected, run_cli("--github", "-n", "2", "--output-only")
    assert_equal expected_clip, clip
  end

  def test_short_count_option_copies_available_history_and_preserves_empty_and_paused_errors
    assert_equal [1, "", "oops: no command found yet.\n"], run_cli("-n", "5")
    add("only", "x\r\n")
    assert_equal [0, "copied: $ only (1 lines)\n", ""], run_cli("-n", "5")
    @log.pause!
    assert_equal [1, "", "oops: recording is paused. Run  oops resume  first.\n"], run_cli("-n", "5")
  end

  def test_short_count_option_rejects_invalid_or_missing_values_without_copying
    add("c1", "one\r\n")
    ["0", "-1", "+1", "1.5", "abc", "2x", ""].each do |value|
      assert_equal [2, "", "oops: -n must be a positive integer\n"], run_cli("-n", value)
    end
    status, out, err = run_cli("-n")
    assert_equal 2, status
    assert_empty out
    assert_match(/missing argument: -n/, err)
    refute File.exist?(@clip)
  end

  def test_command_count_can_only_be_specified_once
    add("c1", "one\r\n")
    [%w[-n 2 -n 3], %w[-n 2 -n 2], %w[2 -n 3], %w[-n 2 3], %w[2 -n 2], %w[err -n 2 -n 3]].each do |args|
      assert_equal [2, "", "oops: specify the command count only once (N or -n)\n"], run_cli(*args), args.inspect
    end
    refute File.exist?(@clip)
  end

  def test_err_with_count_copies_only_latest_failures_oldest_first
    add("old failure", "old\r\n", exit: 1)
    add("first failure", "one\r\n", exit: 2)
    add("success", "ok\r\n")
    add("second failure", "two\r\n", exit: 3)
    add("oops err -n 2", "", exit: 1)
    add("unfinished", "", exit: nil)
    [%w[err -n 2], %w[-n 2 err]].each do |args|
      assert_equal [0, "copied: $ first failure (2 lines)\n", ""], run_cli(*args)
      assert_equal "```\n$ first failure\none\n(exit 2)\n\n$ second failure\ntwo\n(exit 3)\n```\n", clip
    end
    expected = run_cli("err")
    expected_clip = clip
    assert_equal expected, run_cli("err", "-n", "1")
    assert_equal expected_clip, clip
  end

  def test_err_with_count_copies_available_failures_and_supports_formatting
    add("bad", "one\r\ntwo\r\nthree\r\n", exit: 2)
    add("good", "ok\r\n")
    expected = run_cli("err", "--github", "--output-only")
    expected_clip = clip
    assert_equal 0, expected.first
    assert_equal expected, run_cli("err", "-n", "5", "--github", "--output-only")
    assert_equal expected_clip, clip
  end

  def test_err_with_count_preserves_no_failure_error
    add("good", "ok\r\n")
    assert_equal [1, "", "oops: no failed command found.\n"], run_cli("err", "-n", "2")
    refute File.exist?(@clip)
  end

  def test_show_secrets_option
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

  def test_print_writes_text_to_stdout_without_touching_clipboard
    add("c1", "one\r\n")
    add("c2", "two\r\n")
    with_detect(->(*, **) { flunk "clipboard must not be used with --print" }) do
      status, out, err = run_cli("--print")
      assert_equal 0, status
      assert_equal "```\n$ c2\ntwo\n```\n", out
      assert_empty err
      refute File.exist?(@clip)
    end
  end

  def test_print_short_option_matches_long_form
    add("bad", "boom\r\n", exit: 2)
    add("good", "fine\r\n")
    expected = "```console\n$ bad\nboom\n(exit 2)\n```\n"
    with_detect(->(*, **) { flunk "clipboard must not be used with -p" }) do
      assert_equal [0, expected, ""], run_cli("err", "--github", "-p")
      assert_equal [0, expected, ""], run_cli("err", "--github", "--print")
      refute File.exist?(@clip)
    end
  end

  def test_print_masks_secrets
    add("echo $T", "ghp_#{'a' * 36}\r\n")
    assert_equal [0, "```\n$ echo $T\n[secret]\n```\n", ""], run_cli("-p")
  end

  def test_json_writes_records_to_stdout_without_touching_clipboard
    add("c1", "one\r\n")
    add("oops", "copied\r\n")
    add("c2", "ghp_#{'a' * 36}\r\n", exit: 3)
    stamp = Time.at(1).strftime("%Y-%m-%dT%H:%M:%S%:z")
    ended = Time.at(2).strftime("%Y-%m-%dT%H:%M:%S%:z")
    with_detect(->(*, **) { flunk "clipboard must not be used with --json" }) do
      status, out, err = run_cli("--json", "-n", "2")
      assert_equal [0, ""], [status, err]
      assert_equal [{ "command" => "c1", "cwd" => "~", "exit" => 0, "started_at" => stamp, "ended_at" => ended,
                      "output" => "one" },
                    { "command" => "c2", "cwd" => "~", "exit" => 3, "started_at" => stamp, "ended_at" => ended,
                      "output" => "[secret]" }],
                   JSON.parse(out)
      assert_equal out, run_cli("2", "--json", "-p")[1]
      refute File.exist?(@clip)
    end
  end

  def test_json_with_err_and_show_secrets
    add("bad", "ghp_#{'a' * 36}\r\n", exit: 1)
    add("good", "ok\r\n")
    items = JSON.parse(run_cli("err", "--json", "--show-secrets")[1])
    assert_equal([["bad", 1, "ghp_#{'a' * 36}"]], items.map { |i| i.values_at("command", "exit", "output") })
    File.write(@session, "")
    assert_equal [1, "", "oops: no command found yet.\n"], run_cli("--json")
  end

  def test_json_rejects_markdown_formatting_options
    add("c1", "one\r\n")
    %w[--github --time --output-only].each do |option|
      assert_equal [2, "", "oops: --json cannot be combined with #{option}\n"], run_cli("--json", option)
      assert_equal [2, "", "oops: --json cannot be combined with #{option}\n"], run_cli(option, "err", "--json")
    end
  end

  # A stand-in for the GitHub CLI: it saves its arguments and stdin next to
  # itself and prints what a real `gh gist create` prints on stdout.
  def fake_gh(script = 'cat > "$dir/stdin"; echo "https://gist.github.com/someone/abc123"')
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    path = File.join(bin, "gh")
    File.write(path, <<~SH)
      #!/bin/sh
      dir=$(dirname "$0")
      printf '%s\n' "$@" > "$dir/argv"
      #{script}
    SH
    File.chmod(0o755, path)
    @env.merge("PATH" => "#{bin}:/usr/bin:/bin")
  end

  def gh_argv = File.read(File.join(@dir, "bin", "argv")).split("\n")
  def gh_stdin = File.read(File.join(@dir, "bin", "stdin"))

  def test_gist_uploads_the_text_and_copies_the_url
    add("echo $T", "ghp_#{'a' * 36}\r\nmore\r\n", exit: 1)
    env = fake_gh
    assert_equal [0, "gist: https://gist.github.com/someone/abc123 (2 lines, 1 secrets masked)\n", ""],
                 run_cli("--gist", env: env)
    assert_equal %w[gist create - --filename oops.md --desc] << "oops: $ echo $T", gh_argv
    assert_equal "```\n$ echo $T\n[secret]\nmore\n(exit 1)\n```\n", gh_stdin
    assert_equal "https://gist.github.com/someone/abc123", clip
  end

  def test_gist_keeps_formatting_options_and_names_the_first_command
    add("make\nmake test", "boom\r\n", exit: 2)
    env = fake_gh
    assert_equal 0, run_cli("--gist", "--github", env: env).first
    assert_equal "oops: $ make ...", gh_argv.last
    assert_match(/\A```console\n/, gh_stdin)
  end

  def test_gist_rejects_show_secrets_print_and_json
    add("c1", "one\r\n")
    env = fake_gh
    { "--show-secrets" => "--show-secrets", "-p" => "--print", "--print" => "--print",
      "--json" => "--json" }.each do |option, name|
      assert_equal [2, "", "oops: --gist cannot be combined with #{name}\n"], run_cli("--gist", option, env: env)
    end
    refute File.exist?(File.join(@dir, "bin", "argv"))
  end

  def test_gist_without_gh_explains_how_to_get_it
    add("c1", "one\r\n")
    empty = File.join(@dir, "empty")
    FileUtils.mkdir_p(empty)
    message = "oops: --gist needs the GitHub CLI (gh). Install it from https://cli.github.com " \
              "and run  gh auth login  once.\n"
    assert_equal [1, "", message], run_cli("--gist", env: @env.merge("PATH" => empty))
    refute File.exist?(@clip)
  end

  def test_gist_when_gh_is_not_logged_in
    add("c1", "one\r\n")
    env = fake_gh('cat > /dev/null; echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4')
    assert_equal [1, "", "oops: gh is not logged in to GitHub. Run  gh auth login  first.\n"],
                 run_cli("--gist", env: env)
    refute File.exist?(@clip)
  end

  def test_gist_passes_on_other_gh_errors
    add("c1", "one\r\n")
    env = fake_gh('cat > /dev/null; echo "- Creating gist oops.md" >&2; echo "HTTP 502: Bad Gateway" >&2; exit 1')
    assert_equal [1, "", "oops: gh gist create failed: HTTP 502: Bad Gateway\n"], run_cli("--gist", env: env)
    env = fake_gh("cat > /dev/null; echo created")
    assert_equal [1, "", "oops: gh gist create printed no URL\n"], run_cli("--gist", env: env)
  end

  def test_gist_prints_the_url_when_the_clipboard_is_missing
    add("c1", "one\r\n")
    env = fake_gh
    with_detect(->(*, **) {}) do
      status, out, err = run_cli("--gist", env: env)
      assert_equal [0, "gist: https://gist.github.com/someone/abc123 (1 lines)\n"], [status, out]
      assert_match(/\Aoops: warning: the URL was not copied: no clipboard tool found/, err)
    end
  end

  def test_print_works_when_no_clipboard_tool_is_available
    add("c1", "one\r\n")
    with_detect(->(*, **) {}) do
      status, out, err = run_cli("-p")
      assert_equal 0, status
      assert_equal "```\n$ c1\none\n```\n", out
      assert_empty err
    end
  end

  def sessions_dir = File.join(@dir, "state", "oops", "sessions")

  def closed_tab_log
    pid = Process.spawn("true")
    Process.wait(pid)
    FileUtils.mkdir_p(sessions_dir)
    path = File.join(sessions_dir, "20260101-000000-#{pid}.jsonl")
    File.write(path, "x")
    path
  end

  def run_clear(*) = run_cli("clear", *, env: @env.merge("XDG_STATE_HOME" => File.join(@dir, "state")))

  def test_clear_deletes_closed_tabs_logs_and_keeps_this_tab
    logs = [closed_tab_log, closed_tab_log]
    open_tab = File.join(sessions_dir, "20260101-000000-#{Process.pid}.jsonl")
    File.write(open_tab, "x")
    add("c1", "one\r\n")
    assert_equal [0, "removed 2 logs of closed tabs\n", ""], run_clear
    logs.each { |l| refute File.exist?(l) }
    assert File.exist?(open_tab)
    assert_operator File.size(@session), :>, 0
  end

  def test_clear_all_also_empties_this_tabs_log
    closed_tab_log
    add("c1", "one\r\n")
    @log.pause!
    assert_equal [0, "removed 1 log of closed tabs\nemptied this tab's log\n", ""], run_clear("--all")
    assert_equal 0, File.size(@session)
    assert @log.paused?
  end

  def test_clear_with_nothing_to_remove
    assert_equal [0, "removed 0 logs of closed tabs\n", ""], run_clear
  end

  def test_clear_all_when_not_recording_fails_and_removes_nothing
    log = closed_tab_log
    status, out, err = run_cli("clear", "--all", env: @env.merge("OOPS_SESSION" => nil,
                                                                 "XDG_STATE_HOME" => File.join(@dir, "state")))
    assert_equal 1, status
    assert_empty out
    assert_includes err, "not recording in this shell"
    assert File.exist?(log)
  end

  def test_clear_rejects_other_arguments
    status, _, err = run_clear("--al")
    assert_equal 2, status
    assert_equal "oops: usage: oops clear [--all]\n", err
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
    refute File.exist?(@clip)
  end

  def test_unknown_command_and_extra_arguments_exit_two
    assert_equal [2, "", "oops: unknown command: frobnicate\n"], run_cli("frobnicate")
    assert_equal [2, "", "oops: unexpected argument: err\n"], run_cli("3", "err")
    assert_equal [2, "", "oops: invalid option: --tail\n"], run_cli("--tail", "50")
    assert_equal [2, "", "oops: invalid option: --head\n"], run_cli("err", "--head", "20")
  end

  def test_time_and_output_only_options
    add("bundle exec rspec", "....F\n", exit: 1)
    stamp = Time.at(1).strftime("%Y-%m-%d %H:%M:%S %:z")
    assert_equal [0, "copied: $ bundle exec rspec (1 lines)\n", ""], run_cli("--time")
    assert_equal "```\n# #{stamp}\n$ bundle exec rspec\n....F\n(exit 1)\n```\n", clip
    assert_equal [0, "copied: $ bundle exec rspec (1 lines)\n", ""], run_cli("--output-only")
    assert_equal "```\n....F\n(exit 1)\n```\n", clip
  end

  def test_status_reports_recording
    assert_equal [0, "recording\n", ""], run_cli("status")
  end

  def test_status_reports_paused_with_exit_one
    @log.pause!
    assert_equal [1, "paused\n", ""], run_cli("status")
  end

  def test_status_reports_off_without_error_when_not_recording
    assert_equal [1, "off\n", ""], run_cli("status", env: @env.merge("OOPS_SESSION" => ""))
    assert_equal [1, "off\n", ""], run_cli("status", env: @env.merge("OOPS_SESSION" => "#{@dir}/missing.jsonl"))
  end

  def test_status_rejects_arguments
    assert_equal [2, "", "oops: usage: oops status\n"], run_cli("status", "now")
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
