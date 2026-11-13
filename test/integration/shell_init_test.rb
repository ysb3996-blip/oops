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
    %w[OOPS_TTY OOPS_SESSION OOPS_DISABLE __OOPS_SEQ __OOPS_PID __OOPS_SHELL_VERSION ZDOTDIR PROMPT_COMMAND BASH_ENV ENV
       HISTCONTROL HISTFILE __OOPS_GHOSTTY XDG_DATA_DIRS XDG_DATA_HOME GHOSTTY_BASH_INJECT GHOSTTY_RESOURCES_DIR
       GHOSTTY_SHELL_INTEGRATION_XDG_DIR].each { |name| @env[name] = nil }
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

  # fish has no prompt string variable; fish_prompt is a function. The empty
  # greeting keeps the banner off the screen.
  def write_fish_config(before: "", after: "")
    dir = "#{@home}/cfg/fish"
    FileUtils.mkdir_p(dir)
    File.write("#{dir}/config.fish", "#{before}'#{EXE}' init fish | source\n#{after}" \
                                     "function fish_prompt; printf '[st=%s]$ ' $status; end\n" \
                                     "function fish_greeting; end\n")
  end

  def spawn_shell(*argv, prompt: true)
    @r, @w, @pid = PTY.spawn(@env, *argv, chdir: @home)
    @r.winsize = [24, 80]
    @out = +""
    @reader = Thread.new do
      loop do
        chunk = @r.readpartial(4096)
        @out << chunk
        # fish 4 waits for the terminal's answer to this query (Primary
        # Device Attributes) before its first prompt; answer as a VT220.
        @w.write("\e[?62;22c") if chunk.include?("\e[0c") || chunk.include?("\e[c")
      end
    rescue StandardError
      nil
    end
    wait_prompt if prompt
  end

  # Exit status of the spawned shell, waiting at most timeout seconds. The
  # shell can be reaped between the reader thread's read and its append to
  # @out, so the reader is joined first: once the slave side is closed, its
  # read fails and it ends. If something still holds the pty open, the join
  # gives up after 2 seconds and whatever was captured is used.
  def shell_exit_status(timeout: 10)
    deadline = Time.now + timeout
    until Time.now > deadline
      _, status = Process.wait2(@pid, Process::WNOHANG)
      if status
        @reader.join(2)
        return status.exitstatus
      end

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

  def skip_without_fish
    skip "fish not installed" unless system("which fish > /dev/null")
  end

  # --- bash ---

  def test_bash_copies_command_counts_from_the_recorded_shell
    write_bashrc
    check_command_counts("bash")
  end

  # oops doctor runs as a child process, so it sees the shell's version only
  # through the variable the snippet exports.
  def check_doctor_shell_version(shell, version_script)
    version = IO.popen([shell, "-c", version_script], &:read).strip
    @env["SHELL"] = "/bin/#{shell}"
    spawn_shell(shell, "-i")
    assert_equal 0, run_line("'#{EXE}' doctor > '#{@home}/doctor.txt'")
    assert_includes File.read("#{@home}/doctor.txt"), "shell: #{shell} #{version}, hooks: installed\n"
  end

  def check_command_counts(shell, exit_two: "(exit 2)")
    FileUtils.mkdir_p("#{@home}/cfg/oops")
    File.write("#{@home}/cfg/oops/config.yml", "clipboard: \"cat > #{@home}/clip\"\n")
    spawn_shell(shell, "-i")
    assert_equal 1, run_line("echo first; false")
    assert_equal 0, run_line("echo second")
    assert_equal 2, run_line("echo third; #{exit_two}")
    assert_equal 0, run_line("'#{EXE}' -n 2")
    assert_equal "```\n$ echo second\nsecond\n\n$ echo third; #{exit_two}\nthird\n(exit 2)\n```\n",
                 File.read("#{@home}/clip")
    assert_equal 0, run_line("'#{EXE}' err -n 2")
    assert_equal "```\n$ echo first; false\nfirst\n(exit 1)\n\n$ echo third; #{exit_two}\nthird\n(exit 2)\n```\n",
                 File.read("#{@home}/clip")
  end

  def test_bash_doctor_shows_the_shell_version
    write_bashrc
    check_doctor_shell_version("bash", "echo $BASH_VERSION")
  end

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

  def test_zsh_copies_command_counts_from_the_recorded_shell
    skip_without_zsh
    write_zshrc
    check_command_counts("zsh")
  end

  def test_zsh_doctor_shows_the_shell_version
    skip_without_zsh
    write_zshrc
    check_doctor_shell_version("zsh", "echo $ZSH_VERSION")
  end

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

  # --- fish ---

  def test_fish_copies_command_counts_from_the_recorded_shell
    skip_without_fish
    write_fish_config
    check_command_counts("fish", exit_two: "sh -c 'exit 2'")
  end

  def test_fish_doctor_shows_the_shell_version
    skip_without_fish
    write_fish_config
    check_doctor_shell_version("fish", "echo $version")
  end

  def test_fish_config_snippet_records_commands_with_exit_and_cwd
    skip_without_fish
    write_fish_config
    spawn_shell("fish", "-i")
    assert_equal 1, run_line("echo hello; false")
    FileUtils.mkdir_p("#{@home}/sub dir")
    run_line(%(cd "sub dir"))
    assert_equal 4, run_line("pwd >/dev/null; sh -c 'exit 4'")
    run_line("")
    run_line("   ")

    assert_equal 1, session_logs.size
    hello, cd, four = records
    assert_equal 3, records.size
    assert_equal ["echo hello; false", 1], [hello.cmd, hello.exit]
    assert_includes hello.output, "hello\r\n"
    assert_same_dir @home, hello.cwd
    assert_equal [%(cd "sub dir"), 0], [cd.cmd, cd.exit]
    assert_equal ["pwd >/dev/null; sh -c 'exit 4'", 4], [four.cmd, four.exit]
    assert_same_dir "#{@home}/sub dir", four.cwd
    assert_equal [1, 2, 3], records.map(&:seq)
    refute_includes @out, "\e_oops;"
  end

  def test_fish_command_text_round_trips
    skip_without_fish
    write_fish_config
    spawn_shell("fish", "-i")
    cmd = %(echo "it's ü \\$HOME ;" 'x"y'; begin\necho second line\nend)
    run_line(cmd)
    assert_equal [cmd], records.map(&:cmd)
    assert_includes records.first.output, "it's ü $HOME ; x\"y\r\nsecond line\r\n".b
  end

  def test_fish_markers_do_not_go_into_redirected_output
    skip_without_fish
    write_fish_config
    spawn_shell("fish", "-i")
    run_line("begin; echo grp; end > out.txt; echo done")
    assert_equal "grp\n", File.read("#{@home}/out.txt")
    assert_equal "begin; echo grp; end > out.txt; echo done", records.first.cmd
    assert_includes records.first.output, "done\r\n"
  end

  def test_fish_nested_shells_on_the_same_tty_are_not_recorded_twice
    skip_without_fish
    write_fish_config
    spawn_shell("fish", "-i")
    run_line("exec fish")
    run_line("echo inner")
    run_line("fish")
    run_line("echo child")
    run_line("exit")
    run_line("echo parent")
    assert_equal 1, session_logs.size
    assert_equal ["exec fish", "echo inner", "fish", "echo child", "exit", "echo parent"], records.map(&:cmd)
    assert_equal 0, records[0].exit
    assert_includes records[1].output, "inner\r\n"
    assert_includes records[3].output, "child\r\n"
    assert_includes records[5].output, "parent\r\n"
  end

  def test_fish_dash_c_and_scripts_run_without_restart
    skip_without_fish
    write_fish_config
    spawn_shell("fish", "-ic", "echo RAN-C; exit 7", prompt: false)
    assert_equal 7, shell_exit_status
    assert_includes @out, "RAN-C"
    File.write("#{@home}/script.fish", "echo RAN-SCRIPT; exit 8\n")
    spawn_shell("fish", "-i", "script.fish", prompt: false)
    assert_equal 8, shell_exit_status
    assert_includes @out, "RAN-SCRIPT"
    assert_empty session_logs
  end

  def test_fish_login_shell_is_restarted_as_login_shell
    skip_without_fish
    write_fish_config(before: "set -gx PATH #{ENV.fetch('PATH').split(':').map { "'#{_1}'" }.join(' ')}\n")
    spawn_shell("fish", "-l")
    run_line("status is-login; and echo login-yes")
    assert_equal 1, session_logs.size
    assert_includes records.first.output, "login-yes\r\n"
  end

  def test_fish_keeps_working_when_oops_is_missing
    skip_without_fish
    write_fish_config
    File.write("#{@home}/cfg/fish/config.fish",
               "#{Oops::ShellInit.snippet('fish', bin: "#{@home}/gone/oops")}\n" \
               "function fish_prompt; printf '[st=%s]$ ' $status; end\nfunction fish_greeting; end\n")
    spawn_shell("fish", "-i")
    run_line("echo alive-(math 1 + 1)")
    assert_match(/alive-2/, @out)
    assert_includes @out, "oops: cannot run #{@home}/gone/oops; recording disabled"
    assert_empty session_logs
    refute_includes @out, "\e_oops;"
  end

  # --- zsh plugin file (for plugin managers) ---

  PLUGIN = File.expand_path("../../oops.plugin.zsh", __dir__)
  EXE_DIR = File.dirname(EXE)

  def write_plugin_zshrc
    File.write("#{@home}/.zshrc", "source '#{PLUGIN}'\nPS1='[st=%?]%% '\n")
  end

  def test_zsh_plugin_file_records_with_the_oops_next_to_it
    skip_without_zsh
    write_plugin_zshrc
    spawn_shell("zsh", "-i")
    assert_equal 1, run_line("echo hello; false")
    run_line("whence -p oops")
    # The recorded shell sources the plugin again; exe/ is on PATH only once.
    run_line(%(echo n=$(print -rl -- $path | grep -cxF '#{EXE_DIR}')))

    assert_equal ["echo hello; false", 1], [records.first.cmd, records.first.exit]
    assert records[1].output.start_with?("#{EXE}\r\n"), records[1].output.inspect
    assert records[2].output.start_with?("n=1\r\n"), records[2].output.inspect
  end

  # Ruby on PATH too old for oops: init fails, so the shell must not be
  # restarted under oops record (that would close the tab) but run as usual.
  def test_zsh_plugin_keeps_the_shell_when_init_fails
    skip_without_zsh
    FileUtils.mkdir_p("#{@home}/bin")
    File.write("#{@home}/bin/ruby", "#!/bin/sh\necho 'old ruby' >&2\nexit 1\n")
    File.chmod(0o755, "#{@home}/bin/ruby")
    @env["PATH"] = "#{@home}/bin:#{@env['PATH']}"
    write_plugin_zshrc
    spawn_shell("zsh", "-i")
    run_line("echo alive-$((1+1))")

    assert_match(/alive-2/, @out)
    assert_includes @out, "oops: #{EXE} init zsh failed (oops needs Ruby 3.3 or later); recording disabled"
    refute_includes @out, "old ruby"
    assert_empty session_logs
  end

  # --- terminal shell integration (Ghostty) ---

  # A stand-in for Ghostty's zsh integration. Like the real one it is injected
  # through ZDOTDIR; its .zshenv removes the injection again and loads the
  # integration, which logs every shell that loads it (once per shell).
  def install_fake_ghostty
    dir = "#{@home}/ghostty/shell-integration/zsh"
    FileUtils.mkdir_p(dir)
    File.write("#{dir}/ghostty-integration", <<~ZSH)
      (( ! $+_ghostty_state )) || return 0
      typeset -gi _ghostty_state=0
      print -r -- "loaded $$" >> "#{@home}/ghostty.log"
    ZSH
    File.write("#{dir}/.zshenv", <<~ZSH)
      builtin unset ZDOTDIR
      if [[ -o interactive ]]; then
        autoload -Uz "#{dir}/ghostty-integration"
        ghostty-integration
        unfunction ghostty-integration
      fi
    ZSH
    dir
  end

  def ghostty_loads = File.exist?("#{@home}/ghostty.log") ? File.readlines("#{@home}/ghostty.log").uniq.size : 0

  # oops restarts the shell, and the restarted one no longer gets the
  # integration the terminal injected: it has to load it again.
  def test_zsh_recorded_shell_loads_ghosttys_integration_again
    skip_without_zsh
    dir = install_fake_ghostty
    @env.update("ZDOTDIR" => dir, "GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty")
    write_zshrc
    spawn_shell("zsh", "-i")
    run_line("echo recorded-$((1+1))")
    assert_equal 1, session_logs.size, "the tab should be recorded"
    assert_equal 2, ghostty_loads, "outer and restarted shell should each have loaded the integration"
  end

  # GHOSTTY_RESOURCES_DIR is set even when the user turned shell integration
  # off; oops must not switch it on.
  def test_zsh_recorded_shell_does_not_load_ghosttys_integration_when_it_is_off
    skip_without_zsh
    install_fake_ghostty
    @env["GHOSTTY_RESOURCES_DIR"] = "#{@home}/ghostty"
    write_zshrc
    spawn_shell("zsh", "-i")
    run_line("echo recorded-$((1+1))")
    assert_equal 1, session_logs.size
    assert_equal 0, ghostty_loads
  end

  # An inherited flag from an earlier tab must not turn the integration on in
  # a tab whose terminal did not inject it.
  def test_zsh_stale_flag_does_not_load_ghosttys_integration
    skip_without_zsh
    install_fake_ghostty
    @env.update("GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty", "__OOPS_GHOSTTY" => "1")
    write_zshrc
    spawn_shell("zsh", "-i")
    run_line("echo recorded-$((1+1))")
    assert_equal 1, session_logs.size
    assert_equal 0, ghostty_loads
  end

  # A stand-in for Ghostty's bash integration. Ghostty starts bash in POSIX
  # mode with ENV pointing at it (bash 4+; bash 3.2 ignores ENV there); the
  # tests use --rcfile instead, so they run on bash 3.2 too. Like the real
  # one it sources ~/.bashrc with __ghostty_bash_flags set and loads itself
  # afterwards. It logs every shell that gets that far.
  def install_fake_bash_ghostty
    dir = "#{@home}/ghostty/shell-integration/bash"
    FileUtils.mkdir_p(dir)
    File.write("#{dir}/ghostty.bash", <<~BASH)
      if [ -n "$GHOSTTY_BASH_INJECT" ]; then
        builtin declare __ghostty_bash_flags="$GHOSTTY_BASH_INJECT"
        builtin unset ENV GHOSTTY_BASH_INJECT
        [ -r "$HOME/.bashrc" ] && builtin source "$HOME/.bashrc"
        builtin unset __ghostty_bash_flags
      fi
      __ghostty_hook() { :; }
      PROMPT_COMMAND="${PROMPT_COMMAND};__ghostty_hook 2>/dev/null"
      echo "loaded $$" >> "#{@home}/ghostty.log"
    BASH
    "#{dir}/ghostty.bash"
  end

  def test_bash_recorded_shell_loads_ghosttys_integration_again
    file = install_fake_bash_ghostty
    @env.update("GHOSTTY_BASH_INJECT" => "1", "GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty")
    write_bashrc
    spawn_shell("bash", "--rcfile", file, "-i")
    run_line("echo recorded-$((1+1))")
    assert_equal 1, session_logs.size, "the tab should be recorded"
    # The outer shell is replaced while it runs ~/.bashrc, before it gets to
    # the integration, so the restarted shell is the one that loads it.
    assert_equal 1, ghostty_loads
    # bash shows its PROMPT_COMMAND entry as `__ghostty_hook 2> /dev/null`,
    # which must not be taken for the first command.
    assert_equal([["echo recorded-$((1+1))", "recorded-2\n"]], records.map { |r| [r.cmd, r.output.delete("\r")] })
  end

  def test_bash_loads_ghosttys_integration_under_set_u
    file = install_fake_bash_ghostty
    @env.update("GHOSTTY_BASH_INJECT" => "1", "GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty")
    write_bashrc(before: "set -u\n")
    spawn_shell("bash", "--rcfile", file, "-i")
    run_line("case $- in *u*) echo nounset-$((1+1)) ;; esac")
    assert_equal 1, ghostty_loads
    refute_includes @out, "unbound variable"
    assert_equal(["nounset-2\n"], records.map { |r| r.output.delete("\r") })
  end

  def test_bash_recorded_shell_does_not_load_ghosttys_integration_when_it_is_off
    install_fake_bash_ghostty
    @env["GHOSTTY_RESOURCES_DIR"] = "#{@home}/ghostty"
    write_bashrc
    spawn_shell("bash", "-i")
    run_line("echo recorded-$((1+1))")
    assert_equal 1, session_logs.size
    assert_equal 0, ghostty_loads
  end

  def test_bash_stale_flag_does_not_load_ghosttys_integration
    install_fake_bash_ghostty
    @env.update("GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty", "__OOPS_GHOSTTY" => "1")
    write_bashrc
    spawn_shell("bash", "-i")
    run_line("echo recorded-$((1+1))")
    assert_equal 1, session_logs.size
    assert_equal 0, ghostty_loads
  end

  # A stand-in for Ghostty's fish integration. Like the real one it is
  # injected through XDG_DATA_DIRS as a vendor_conf.d file, removes the
  # injection again, and defines __ghostty_setup, which runs on the first
  # prompt. It logs every shell that loads it.
  def install_fake_fish_ghostty
    data = "#{@home}/ghostty/shell-integration"
    FileUtils.mkdir_p("#{data}/fish/vendor_conf.d")
    File.write("#{data}/fish/vendor_conf.d/ghostty-shell-integration.fish", <<~FISH)
      set -l keep
      for d in (string split : -- "$XDG_DATA_DIRS")
          test "$d" = "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR"; or set -a keep $d
      end
      set -gx XDG_DATA_DIRS (string join : -- $keep)
      set -e GHOSTTY_SHELL_INTEGRATION_XDG_DIR
      status is-interactive; or return
      function __ghostty_setup --on-event fish_prompt
          functions -e __ghostty_setup
      end
      echo "loaded $fish_pid" >> "#{@home}/ghostty.log"
    FISH
    data
  end

  def test_fish_recorded_shell_loads_ghosttys_integration_again
    skip_without_fish
    dir = install_fake_fish_ghostty
    @env.update("XDG_DATA_DIRS" => dir, "GHOSTTY_SHELL_INTEGRATION_XDG_DIR" => dir,
                "GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty")
    write_fish_config
    spawn_shell("fish", "-i")
    run_line("echo recorded")
    assert_equal 1, session_logs.size, "the tab should be recorded"
    assert_equal 2, ghostty_loads, "outer and restarted shell should each have loaded the integration"
  end

  def test_fish_recorded_shell_does_not_load_ghosttys_integration_when_it_is_off
    skip_without_fish
    install_fake_fish_ghostty
    @env["GHOSTTY_RESOURCES_DIR"] = "#{@home}/ghostty"
    write_fish_config
    spawn_shell("fish", "-i")
    run_line("echo recorded")
    assert_equal 1, session_logs.size
    assert_equal 0, ghostty_loads
  end

  def test_fish_stale_flag_does_not_load_ghosttys_integration
    skip_without_fish
    install_fake_fish_ghostty
    @env.update("GHOSTTY_RESOURCES_DIR" => "#{@home}/ghostty", "__OOPS_GHOSTTY" => "1")
    write_fish_config
    spawn_shell("fish", "-i")
    run_line("echo recorded")
    assert_equal 1, session_logs.size
    assert_equal 0, ghostty_loads
  end

  # --- bash-preexec ---

  # bash-preexec (also behind atuin, Ghostty's bash integration and others)
  # wants to own the DEBUG trap and the end of PROMPT_COMMAND, as oops's own
  # hooks do. oops hands its hooks to it instead. The real files are checked in
  # as fixtures; the order of the two rc lines must not matter.
  %w[0.6.0 0.7.0].each do |version|
    %i[before after].each do |order|
      define_method("test_bash_with_bash_preexec_#{version.tr('.', '_')}_loaded_#{order}_records_every_command") do
        preexec = %(source "#{File.expand_path("../fixtures/bash-preexec/#{version}/bash-preexec.sh", __dir__)}"\n)
        order == :before ? write_bashrc(before: preexec) : write_bashrc(after: preexec)
        spawn_shell("bash", "-i")
        assert_equal 1, run_line("echo hello; false")
        assert_equal 3, run_line("sh -c 'exit 3'")
        run_line("echo aa bb")
        run_line(%(echo "last=$_"))
        run_line("echo fifth")

        assert_equal ["echo hello; false", "sh -c 'exit 3'", "echo aa bb", %(echo "last=$_"), "echo fifth"],
                     records.map(&:cmd)
        assert_equal [1, 3, 0, 0, 0], records.map(&:exit)
        assert_equal [1, 2, 3, 4, 5], records.map(&:seq)
        assert_equal "last=bb\r\n", records[3].output
        refute_includes @out, "\e_oops;"
      end
    end
  end
end
