require "test_helper"
require "pty"
require "io/console"
require "fileutils"

# Runs real bash/zsh on a pty with the init snippet in their rc files, as a
# user would: the shell starts unrecorded, the snippet re-execs it under
# `oops record`, and the hooks' markers end up as records in the session log.
class ShellInitIntegrationTest < Minitest::Test
  EXE = File.expand_path("../../exe/oops", __dir__)
  PROMPT = /\[st=(\d+)\][$%] /
  # `command` and friends are shell builtins, so resolve them through `sh -c`.
  def self.sh_capture(script) = IO.popen(["sh", "-c", script], err: File::NULL, &:read).to_s
  UTF8_LOCALE = %w[C.UTF-8 en_US.UTF-8].find { |l| sh_capture("locale -a").lines.map(&:strip).include?(l) }

  def setup
    @home = Dir.mktmpdir
    @env = { "HOME" => @home, "XDG_STATE_HOME" => "#{@home}/state", "XDG_CONFIG_HOME" => "#{@home}/cfg",
             "PATH" => ENV.fetch("PATH", nil), "TERM" => "xterm", "LC_ALL" => UTF8_LOCALE,
             "BASH_SILENCE_DEPRECATION_WARNING" => "1",
             # Debian/Ubuntu's /etc/zsh/zshrc runs compinit unless this is set; on CI runners
             # (group-writable dirs on fpath) it stops at an "insecure directories" prompt.
             "skip_global_compinit" => "1" }
    %w[OOPS_TTY OOPS_SESSION OOPS_DISABLE __OOPS_SEQ __OOPS_PID ZDOTDIR PROMPT_COMMAND BASH_ENV ENV
       HISTCONTROL HISTFILE].each { |name| @env[name] = nil }
    @prompts = 0
  end

  def teardown
    begin
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    rescue StandardError
      nil
    end
    @reader&.kill
    FileUtils.rm_rf(@home)
  end

  # --- harness ---

  def snippet_line(shell) = %(eval "$('#{EXE}' init #{shell})"\n)

  def write_bashrc(before: "", after: "", file: ".bashrc")
    File.write("#{@home}/#{file}", "#{before}#{snippet_line('bash')}#{after}PS1='[st=$?]$ '\n")
  end

  def write_zshrc(after: "")
    File.write("#{@home}/.zshrc", "#{snippet_line('zsh')}#{after}PS1='[st=%?]%% '\n")
  end

  def spawn_shell(*argv, prompt: true)
    @r, @w, @pid = PTY.spawn(@env, *argv, chdir: @home)
    @r.winsize = [24, 80]
    @out = +""
    @reader = Thread.new do
      loop { @out << @r.readpartial(4096) }
    rescue StandardError
      nil
    end
    wait_prompt if prompt
  end

  # Exit status of the spawned shell, waiting at most timeout seconds.
  def shell_exit_status(timeout: 10)
    deadline = Time.now + timeout
    until Time.now > deadline
      _, status = Process.wait2(@pid, Process::WNOHANG)
      return status.exitstatus if status

      sleep 0.05
    end
    flunk "shell did not exit; screen so far:\n#{@out}"
  end

  def bash_version
    IO.popen(["bash", "-c", 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"'], &:read).split.map(&:to_i)
  end

  def prompt_count = @out.scan(PROMPT).size

  # Waits for the next prompt; returns the $? it shows.
  def wait_prompt(timeout: 10)
    deadline = Time.now + timeout
    sleep 0.02 until prompt_count > @prompts || Time.now > deadline
    assert_operator prompt_count, :>, @prompts, "no prompt; screen so far:\n#{@out}"
    @prompts = prompt_count
    @out.scan(PROMPT).last[0].to_i
  end

  # Types one command line and waits until the shell prompts again.
  def run_line(text)
    @w.write("#{text}\n")
    wait_prompt
  end

  def session_logs = Dir.glob("#{@home}/state/oops/sessions/*.jsonl")

  def records
    session_logs.flat_map { |f| File.readlines(f).map { |l| Oops::Record.from_json_line(l) } }
  end

  def assert_same_dir(expected, actual)
    assert_equal File.realpath(expected), File.realpath(actual)
  end

  def skip_without_zsh
    skip "zsh not installed" unless system("which zsh > /dev/null")
  end

  # --- bash ---

  def test_bash_rc_snippet_records_commands_with_exit_and_cwd
    write_bashrc
    spawn_shell("bash", "-i")
    run_line("echo hello; false")
    FileUtils.mkdir_p("#{@home}/sub dir")
    run_line(%(cd "sub dir"))
    run_line("pwd >/dev/null; sh -c 'exit 3'")

    assert_equal 1, session_logs.size
    hello, cd, three = records
    assert_equal ["echo hello; false", 1, "hello\r\n"], [hello.cmd, hello.exit, hello.output]
    assert_same_dir @home, hello.cwd
    assert_equal [%(cd "sub dir"), 0, ""], [cd.cmd, cd.exit, cd.output]
    assert_equal ["pwd >/dev/null; sh -c 'exit 3'", 3], [three.cmd, three.exit]
    assert_same_dir "#{@home}/sub dir", three.cwd
    assert_equal [1, 2, 3], records.map(&:seq)
    refute_includes @out, "\e_oops;"
  end

  def test_bash_command_text_round_trips
    write_bashrc
    spawn_shell("bash", "-i")
    cmd = %(echo "it's `echo bq` ü \\$HOME ;\nsecond line"; printf '%s\\n' 'a;b' "x\\"y")
    run_line(cmd)
    assert_equal [cmd], records.map(&:cmd)
    assert_equal "it's bq ü $HOME ;\r\nsecond line\r\na;b\r\nx\"y\r\n".b, records.first.output
  end

  def test_bash_keeps_status_last_arg_and_prompt_command
    write_bashrc(before: %(PROMPT_COMMAND='echo "pc-before=$?"'\n),
                 after: %(PROMPT_COMMAND="$PROMPT_COMMAND; echo pc-after"\n))
    spawn_shell("bash", "-i")
    assert_equal 5, run_line("sh -c 'exit 5'")
    assert_match(/pc-before=5\r\npc-after\r\n[^\n]*\[st=5\]/, @out)
    run_line(%(echo aa bb; echo "last=$_"))
    assert_equal([["sh -c 'exit 5'", 5, ""], [%(echo aa bb; echo "last=$_"), 0, "aa bb\r\nlast=bb\r\n"]],
                 records.map { [_1.cmd, _1.exit, _1.output] })
  end

  def test_bash_empty_lines_make_no_records
    write_bashrc(after: %(PROMPT_COMMAND="${PROMPT_COMMAND:-}"$'\\n'"[ -n x ] && : pc-entry"\n))
    spawn_shell("bash", "-i")
    run_line("")
    run_line("   ")
    run_line("echo one")
    run_line("")
    run_line("echo two")
    assert_equal ["echo one", "echo two"], records.map(&:cmd)
  end

  # bash 5.1+ runs every element of an array PROMPT_COMMAND.
  def test_bash_array_prompt_command_entries_are_kept
    skip "needs bash 5.1+ (array PROMPT_COMMAND)" if (bash_version <=> [5, 1]).negative?

    write_bashrc(after: %(PROMPT_COMMAND+=('echo "pc1=$?"; true' 'echo pc2')\n))
    spawn_shell("bash", "-i")
    run_line("sh -c 'exit 6'")
    assert_match(/pc1=6\r\npc2\r\n/, @out)
    run_line("")
    run_line("echo two")
    assert_equal([["sh -c 'exit 6'", 6, ""], ["echo two", 0, "two\r\n"]],
                 records.map { [_1.cmd, _1.exit, _1.output] })
  end

  def test_bash_chains_an_existing_debug_trap
    write_bashrc(after: %(trap '__t=$_; dbg=$((dbg+1)); : "$__t"' DEBUG\n))
    spawn_shell("bash", "-i")
    run_line(%(dbg=0; echo aa bb; echo "last=$_ dbg=$dbg"))
    assert_equal "aa bb\r\nlast=bb dbg=2\r\n", records.first.output
  end

  def test_bash_markers_do_not_go_into_redirected_output
    write_bashrc
    spawn_shell("bash", "-i")
    run_line("{ echo grp; } > out.txt; echo done")
    assert_equal "grp\n", File.read("#{@home}/out.txt")
    assert_equal ["{ echo grp; } > out.txt; echo done", "done\r\n"], [records.first.cmd, records.first.output]
  end

  # A line the history did not save (ignorespace, ignoredups, HISTIGNORE)
  # must not get the text of the older entry; it falls back to the first
  # simple command.
  def test_bash_lines_left_out_of_history_do_not_get_an_older_text
    write_bashrc(after: "HISTCONTROL=ignoreboth\nHISTIGNORE='ls'\n")
    spawn_shell("bash", "-i")
    run_line("echo x; ls >/dev/null")
    run_line("ls >/dev/null")
    run_line("ls")
    run_line("echo hello world")
    run_line(" echo hello")
    run_line("echo again")
    run_line("echo again")
    assert_equal ["echo x; ls >/dev/null", "ls >/dev/null", "ls", "echo hello world", "echo hello",
                  "echo again", "echo again"], records.map(&:cmd)
  end

  def test_bash_nounset_in_rc_keeps_hooks_working
    write_bashrc(after: "set -u\n")
    spawn_shell("bash", "-i")
    run_line("echo one")
    run_line("")
    run_line("echo two; false")
    assert_equal([["echo one", 0], ["echo two; false", 1]], records.map { [_1.cmd, _1.exit] })
    refute_match(/unbound|bash: /, @out)
  end

  def test_bash_errexit_in_rc_keeps_the_shell_alive
    write_bashrc(before: %(PROMPT_COMMAND='echo "pc=$?"'\n), after: %(set -e\ntrap ': "$_"' DEBUG\n))
    spawn_shell("bash", "-i")
    assert_equal 1, run_line("false && true")
    assert_match(/pc=1\r\n/, @out)
    run_line(%(echo "prev=$?"))
    run_line("false || echo fb")
    run_line(%(echo aa bb; echo "last=$_"))
    assert_nil Process.wait2(@pid, Process::WNOHANG)
    assert_equal([["false && true", 1, ""], [%(echo "prev=$?"), 0, "prev=1\r\n"], ["false || echo fb", 0, "fb\r\n"],
                  [%(echo aa bb; echo "last=$_"), 0, "aa bb\r\nlast=bb\r\n"]],
                 records.map { [_1.cmd, _1.exit, _1.output] })
  end

  # Re-sourcing an rc that adds PROMPT_COMMAND entries around ours.
  def test_bash_resourced_rc_is_wrapped_again
    write_bashrc(after: %(PROMPT_COMMAND="history -a; $PROMPT_COMMAND; echo pc-tail"\n))
    spawn_shell("bash", "-i")
    run_line(". ~/.bashrc")
    assert_equal 1, run_line("false")
    run_line("")
    run_line("case $PROMPT_COMMAND in __oops_precmd*__oops_arm) echo wrapped-ok;; esac")
    assert_equal([[". ~/.bashrc", 0, ""], ["false", 1, ""]], records.first(2).map { [_1.cmd, _1.exit, _1.output] })
    assert_equal ["wrapped-ok\r\n"], records.drop(2).map(&:output)
    assert_equal 3, records.size
  end

  # bind -x widgets (fzf, atuin) run commands at the prompt; bash 4+ marks
  # them with READLINE_LINE.
  def test_bash_bind_x_widget_does_not_take_the_next_record
    skip "needs bash 4+ (READLINE_LINE)" if (bash_version <=> [4, 0]).negative?

    write_bashrc(after: %(bind -x '"\\C-t": "echo widget-out"'\n))
    spawn_shell("bash", "-i")
    run_line("echo before")
    @w.write("\x14")
    deadline = Time.now + 5
    sleep 0.02 until @out.include?("widget-out") || Time.now > deadline
    sleep 0.3
    @prompts = prompt_count
    run_line("echo after")
    assert_equal([["echo before", "before\r\n"], ["echo after", "after\r\n"]], records.map { [_1.cmd, _1.output] })
  end

  def test_bash_dash_c_and_scripts_run_without_restart
    write_bashrc
    spawn_shell("bash", "-ic", "echo RAN-C; exit 7", prompt: false)
    assert_equal 7, shell_exit_status
    assert_includes @out, "RAN-C"
    File.write("#{@home}/script.sh", "echo RAN-SCRIPT; exit 8\n")
    spawn_shell("bash", "-i", "script.sh", prompt: false)
    assert_equal 8, shell_exit_status
    assert_includes @out, "RAN-SCRIPT"
    assert_empty session_logs
  end

  def test_bash_nested_shells_on_the_same_tty_are_not_recorded_twice
    write_bashrc
    spawn_shell("bash", "-i")
    run_line("exec bash")
    run_line("echo inner-$((1+1))")
    run_line("bash")
    run_line("echo child")
    run_line("exit")
    run_line("echo parent")
    assert_equal 1, session_logs.size
    cmds = records.map(&:cmd)
    assert_equal ["exec bash", "echo inner-$((1+1))", "bash", "echo child", "exit", "echo parent"], cmds
    assert_equal [0, "inner-2\r\n"], [records[0].exit, records[1].output]
    assert_equal ["child\r\n", "parent\r\n"], [records[3].output, records[5].output]
  end

  def test_bash_login_shell_is_restarted_as_login_shell
    # /etc/profile may reset PATH (macOS path_helper); oops needs its Ruby.
    write_bashrc(file: ".bash_profile", before: "export PATH='#{ENV.fetch('PATH')}'\n")
    spawn_shell("bash", "-l")
    run_line("shopt -q login_shell && echo login-yes")
    assert_equal 1, session_logs.size
    assert_equal "login-yes\r\n", records.first.output
  end

  def test_bash_without_a_tty_name_is_left_alone
    # tty(1) failing (here a function shadows it) must not re-exec the shell,
    # even with an OOPS_TTY inherited from elsewhere.
    @env["OOPS_TTY"] = "/dev/oops-elsewhere"
    write_bashrc(before: "tty() { return 1; }\n")
    spawn_shell("bash", "-i")
    run_line("echo alive-$((1+1))")
    assert_match(/alive-2/, @out)
    assert_empty session_logs
  end

  def test_bash_keeps_working_when_oops_is_missing
    File.write("#{@home}/.bashrc", "#{Oops::ShellInit.snippet('bash', bin: "#{@home}/gone/oops")}PS1='[st=$?]$ '\n")
    spawn_shell("bash", "-i")
    run_line("echo alive-$((1+1))")
    assert_match(/alive-2/, @out)
    assert_includes @out, "oops: cannot run #{@home}/gone/oops; recording disabled"
    assert_empty session_logs
    refute_includes @out, "\e_oops;"
  end

  # --- zsh ---

  def test_zsh_rc_snippet_records_commands_with_exit_and_cwd
    skip_without_zsh
    write_zshrc
    spawn_shell("zsh", "-i")
    assert_equal 1, run_line("echo hello; false")
    FileUtils.mkdir_p("#{@home}/sub dir")
    run_line(%(cd "sub dir"))
    assert_equal 4, run_line("pwd >/dev/null; (exit 4)")
    run_line("")
    run_line("   ")

    assert_equal 1, session_logs.size
    hello, cd, four = records
    assert_equal 3, records.size
    assert_equal ["echo hello; false", 1], [hello.cmd, hello.exit]
    assert hello.output.start_with?("hello\r\n"), hello.output.inspect
    assert_same_dir @home, hello.cwd
    assert_equal [%(cd "sub dir"), 0], [cd.cmd, cd.exit]
    assert_equal ["pwd >/dev/null; (exit 4)", 4], [four.cmd, four.exit]
    assert_same_dir "#{@home}/sub dir", four.cwd
    assert_equal [1, 2, 3], records.map(&:seq)
    refute_includes @out, "\e_oops;"
  end

  def test_zsh_command_text_round_trips
    skip_without_zsh
    write_zshrc
    spawn_shell("zsh", "-i")
    cmd = %(echo "it's `echo bq` ü \\$HOME ;\nsecond line"; printf '%s\\n' 'a;b' "x\\"y")
    run_line(cmd)
    assert_equal [cmd], records.map(&:cmd)
    assert records.first.output.start_with?("it's bq ü $HOME ;\r\nsecond line\r\na;b\r\nx\"y\r\n".b)
  end

  def test_zsh_nested_exec_is_not_recorded_twice
    skip_without_zsh
    write_zshrc
    spawn_shell("zsh", "-i")
    run_line("exec zsh")
    run_line("echo inner-$((1+1))")
    assert_equal 1, session_logs.size
    assert_equal([["exec zsh", 0], ["echo inner-$((1+1))", 0]], records.map { [_1.cmd, _1.exit] })
    assert records[1].output.start_with?("inner-2\r\n")
  end

  def test_zsh_dash_c_and_scripts_run_without_restart
    skip_without_zsh
    write_zshrc
    spawn_shell("zsh", "-ic", "echo RAN-C; exit 7", prompt: false)
    assert_equal 7, shell_exit_status
    assert_includes @out, "RAN-C"
    File.write("#{@home}/script.zsh", "echo RAN-SCRIPT; exit 8\n")
    spawn_shell("zsh", "-i", "script.zsh", prompt: false)
    assert_equal 8, shell_exit_status
    assert_includes @out, "RAN-SCRIPT"
    assert_empty session_logs
  end

  def test_zsh_login_shell_restarts_the_same_zsh_binary
    skip_without_zsh
    real = self.class.sh_capture("command -v zsh").strip
    FileUtils.mkdir_p("#{@home}/zbin")
    File.symlink(real, "#{@home}/zbin/zsh")
    @env["SHELL"] = "#{@home}/zbin/zsh"
    # /etc/zprofile may reset PATH (macOS path_helper); oops needs its Ruby.
    File.write("#{@home}/.zshrc", "export PATH='#{ENV.fetch('PATH')}'\n#{snippet_line('zsh')}PS1='[st=%?]%% '\n")
    spawn_shell([real, "-zsh"])
    run_line('print -r -- "argzero=$ZSH_ARGZERO"')
    assert_equal 1, session_logs.size
    out = records.first.output
    assert out.start_with?("argzero=#{@home}/zbin/zsh\r\n".b), out.inspect
  end

  def test_zsh_ignore_close_braces_in_rc
    skip_without_zsh
    File.write("#{@home}/.zshrc", "setopt IGNORE_CLOSE_BRACES\n#{snippet_line('zsh')}PS1='[st=%?]%% '\n")
    spawn_shell("zsh", "-i")
    run_line("echo one")
    assert_equal ["echo one"], records.map(&:cmd)
  end

  def test_zsh_keeps_working_when_oops_is_missing
    skip_without_zsh
    File.write("#{@home}/.zshrc", "#{Oops::ShellInit.snippet('zsh', bin: "#{@home}/gone/oops")}PS1='[st=%?]%% '\n")
    spawn_shell("zsh", "-i")
    run_line("echo alive-$((1+1))")
    assert_match(/alive-2/, @out)
    assert_includes @out, "oops: cannot run #{@home}/gone/oops; recording disabled"
    assert_empty session_logs
  end
end
