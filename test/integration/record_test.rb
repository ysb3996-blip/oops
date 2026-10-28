require "test_helper"
require "pty"
require "io/console"
require "fileutils"

class RecordIntegrationTest < Minitest::Test
  EXE = File.expand_path("../../exe/oops", __dir__)
  BASH = %w[bash --norc --noprofile -i].freeze

  def setup
    @home = Dir.mktmpdir
    @env = { "HOME" => @home, "XDG_STATE_HOME" => "#{@home}/state", "XDG_CONFIG_HOME" => "#{@home}/cfg",
             "PATH" => ENV.fetch("PATH", nil), "TERM" => "xterm", "OOPS_TTY" => nil, "OOPS_SESSION" => nil }
    FileUtils.mkdir_p("#{@home}/cfg/oops")
    File.write("#{@home}/cfg/oops/config.yml", "clipboard: \"cat > #{@home}/clip\"\n")
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

  def spawn_recorded(shell_argv)
    @r, @w, @pid = PTY.spawn(@env, EXE, "record", "--", *shell_argv)
    @r.winsize = [24, 80]
    @out = +""
    @reader = Thread.new do
      loop { @out << @r.readpartial(4096) }
    rescue StandardError
      nil
    end
  end

  def type(text)
    @w.write(text)
    sleep 0.3
  end

  def wait_for(pattern, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.05 until @out =~ pattern || Time.now > deadline
    assert_match pattern, @out
  end

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    sleep 0.05 until (value = yield) || Time.now > deadline
    value
  end

  def session_logs = Dir.glob("#{@home}/state/oops/sessions/*.jsonl")

  # Shell text that prints a marker; printf turns \033 and \\ into ESC and "\".
  def printf_marker(body) = "printf '\\033_oops;#{body}\\033\\\\'"

  def b64(text) = [text].pack("m0")

  def test_bash_records_commands_and_oops_copies_last
    skip "needs Task 10 (oops init) and Task 12 (oops copy)"
    spawn_recorded(BASH)
    type(%(eval "$(#{EXE} init bash)"\n))
    type("echo hello; false\n")
    type("echo world\n")
    type("#{EXE}\n")
    wait_for(/copied: \$ echo world \(1 lines\)/)
    assert_equal "```\n$ echo world\nworld\n```\n", File.read("#{@home}/clip")
    type("#{EXE} err\n")
    wait_for(/copied: \$ echo hello; false/)
    assert_equal "```\n$ echo hello; false\nhello\n(exit 1)\n```\n", File.read("#{@home}/clip")
    type("exit 7\n")
    assert_equal 7, Process.wait2(@pid)[1].exitstatus
  end

  def test_zsh_records_commands
    skip "needs Task 10 (oops init) and Task 12 (oops copy)"
    skip "zsh not installed" unless system("which zsh > /dev/null")
    spawn_recorded(%w[zsh -f -i])
    type(%(eval "$(#{EXE} init zsh)"\n))
    type("echo hi\n")
    type("#{EXE}\n")
    wait_for(/copied: \$ echo hi/)
    assert_equal "```\n$ echo hi\nhi\n```\n", File.read("#{@home}/clip")
  end

  def test_resize_is_forwarded_to_inner_shell
    spawn_recorded(BASH)
    type("stty size\n")
    wait_for(/24 80/)
    @r.winsize = [50, 120]
    sleep 0.3
    type("stty size\n")
    wait_for(/50 120/)
  end

  def test_markers_never_reach_the_terminal
    spawn_recorded(BASH)
    type(%(eval "$(#{EXE} init bash)"\n))
    type("echo x\n")
    sleep 0.5
    refute_includes @out, "\e_oops;"
  end

  def test_unwritable_log_dir_keeps_shell_working
    FileUtils.mkdir_p("#{@home}/state/oops")
    File.write("#{@home}/state/oops/sessions", "not a dir")
    spawn_recorded(BASH)
    type("echo alive\n")
    wait_for(/alive/)
    statuses = Dir.glob("#{@home}/state/oops/**/*.status").map { File.read(_1) }.join
    assert_match(/recording disabled|log-error/, @out + statuses)
  end

  def test_hook_markers_become_log_records_and_are_hidden
    spawn_recorded(BASH)
    start = printf_marker("start;1;1700000000;#{b64('/tmp')};#{b64('echo hi')}")
    type("#{start}; echo hi; #{printf_marker('end;1;3')}; echo done-$((40+2))\n")
    wait_for(/done-42/)
    line = wait_until { session_logs.first && File.read(session_logs.first)[/.*\n/] }
    record = Oops::Record.from_json_line(line)
    assert_equal [1, "echo hi", "/tmp", 1_700_000_000, 3],
                 [record.seq, record.cmd, record.cwd, record.started_at, record.exit]
    assert_equal "hi\r\n", record.output
    assert_equal "ok", File.read("#{session_logs.first}.status")
    refute_includes @out, "\e_oops;"
  end

  def test_child_env_names_session_and_child_tty
    spawn_recorded(BASH)
    type(%(echo "S=$OOPS_SESSION"; [ "$OOPS_TTY" = "$(tty)" ] && echo same-tty-$((1+1))\n))
    wait_for(/same-tty-2/)
    assert_equal 1, session_logs.size
    assert_includes @out, "S=#{session_logs.first}"
  end

  def test_nested_record_execs_the_shell_without_recording_again
    spawn_recorded(BASH)
    type("#{EXE} record -- #{BASH.join(' ')}\n")
    type("echo nested-$((1+1))\n")
    wait_for(/nested-2/)
    assert_equal 1, session_logs.size
    type("exit 5\n")
    type("exit 6\n")
    assert_equal 6, Process.wait2(@pid)[1].exitstatus
  end

  def test_exit_status_of_the_shell_is_returned
    spawn_recorded(BASH)
    type("exit 7\n")
    assert_equal 7, Process.wait2(@pid)[1].exitstatus
  end

  def test_signal_death_of_the_shell_returns_128_plus_signo
    spawn_recorded(BASH)
    type("kill -KILL $$\n")
    assert_equal 128 + 9, Process.wait2(@pid)[1].exitstatus
  end

  def test_output_after_exit_is_drained
    spawn_recorded(BASH)
    type("head -c 200000 /dev/zero | tr '\\0' 'a'; echo; echo tail-marker; exit 0\n")
    status = Process.wait2(@pid)[1]
    wait_for(/tail-marker/)
    assert_equal 0, status.exitstatus
  end

  def test_background_job_holding_the_pty_does_not_keep_the_recorder_alive
    spawn_recorded(BASH)
    type(%(bash -c 'trap "" HUP; echo bg-pid-$$; exec sleep 20' & disown; sleep 0.2; exit 3\n))
    started = Time.now
    status = Process.wait2(@pid)[1]
    assert_equal 3, status.exitstatus
    assert_operator Time.now - started, :<, 5
  ensure
    bg = @out.to_s[/bg-pid-(\d+)/, 1]
    Process.kill("KILL", bg.to_i) if bg
  end

  def test_terminal_settings_are_restored_after_the_shell_exits
    script = %(stty -g; #{EXE} record -- sh -c 'exit 0'; stty -g; echo restored-check)
    r, _w, pid = PTY.spawn(@env, "sh", "-c", script)
    out = +""
    begin
      loop { out << r.readpartial(4096) }
    rescue Errno::EIO, EOFError
      nil
    end
    Process.wait(pid)
    assert_match(/restored-check/, out)
    before, after = out.lines.map(&:strip).grep(/\A(gfmt1:|\h+:\h+:)/).first(2).map { without_pendin(_1) }
    refute_nil after
    assert_equal before, after
  end

  # macOS sets PENDIN (0x20000000 in lflag) by itself whenever canonical mode
  # is switched back on; `stty raw; stty -raw` does the same.
  def without_pendin(stty_g)
    stty_g.sub(/lflag=(\h+)/) { "lflag=#{(Regexp.last_match(1).hex & ~0x20000000).to_s(16)}" }
  end

  def test_log_write_failure_keeps_relaying
    skip "chmod 000 does not stop root" if Process.uid.zero?
    spawn_recorded(BASH)
    type(%(chmod 000 "$OOPS_SESSION"\n))
    type("#{printf_marker("start;1;1;#{b64('/')};#{b64('x')}")}; #{printf_marker('end;1;0')}\n")
    type("echo still-$((1+1))\n")
    wait_for(/still-2/)
    assert_match(/oops: warning: session log write failed \(.*\); recording disabled/, @out)
    assert_match(/\Alog-error: /, File.read("#{session_logs.first}.status"))
  end
end
