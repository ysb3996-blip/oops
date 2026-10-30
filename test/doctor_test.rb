require "test_helper"
require "pty"

class DoctorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @env = { "HOME" => @dir, "SHELL" => "/bin/zsh", "ZSH_VERSION" => "5.9", "XDG_CONFIG_HOME" => File.join(@dir, "c") }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def report(env = @env, config: Oops::Config.new(File.join(@dir, "none.yml")), tty: "/dev/ttys001")
    Oops::Doctor.report(env: env, config: config, sessions_dir: File.join(@dir, "s"), tty: tty,
                        which: ->(c) { c == "pbcopy" })
  end

  def test_reports_not_recording_when_env_missing
    out = report
    assert_includes out, "recording: no\n"
    assert_includes out, "shell: zsh 5.9, hooks: missing\n"
    assert_includes out, "sessions: 0 files, 0.0 MB\n"
    assert_match(/^ruby: #{Regexp.escape(RUBY_VERSION)} /, out)
    assert_match(/^config: .*config.yml \(missing\)$/, out)
  end

  def test_reports_recording_paused_and_sizes
    sd = File.join(@dir, "s")
    FileUtils.mkdir_p(sd)
    log = File.join(sd, "a.jsonl")
    File.write(log, "x" * 1_048_576)
    File.write("#{log}.status", "ok")
    File.write("#{log}.paused", "")
    env = @env.merge("OOPS_SESSION" => log, "OOPS_TTY" => "/dev/ttys001", "__OOPS_SEQ" => "3")
    out = report(env)
    assert_includes out, "recording: yes (#{log})\n"
    assert_includes out, "this terminal: recorded\n"
    assert_includes out, "log writable: yes (ok)\n"
    assert_includes out, "paused: yes\n"
    assert_includes out, "hooks: installed"
    assert_includes out, "sessions: 3 files, 1.0 MB\n"
  end

  def test_reports_log_error_from_status_file
    log = File.join(@dir, "b.jsonl")
    File.write(log, "")
    File.write("#{log}.status", "log-error: disk full")
    out = report(@env.merge("OOPS_SESSION" => log))
    assert_includes out, "log writable: no (log-error: disk full)\n"
    assert_includes out, "paused: no\n"
  end

  def test_tolerates_missing_session_file
    out = report(@env.merge("OOPS_SESSION" => File.join(@dir, "gone.jsonl")))
    assert_includes out, "log file missing"
    assert_includes out, "log writable: no"
  end

  def test_warns_when_clipboard_is_true
    path = File.join(@dir, "c.yml")
    File.write(path, "clipboard: true\n")
    assert_includes report(config: Oops::Config.new(path)), "warning: config clipboard is \"true\""
  end

  def test_warns_about_bashrc_debug_trap_and_prompt_command
    File.write(File.join(@dir, ".bashrc"), "trap 'x' DEBUG\nPROMPT_COMMAND='y'\n")
    out = report(@env.merge("SHELL" => "/bin/bash"))
    assert_includes out, "DEBUG trap"
    assert_includes out, "PROMPT_COMMAND without appending"
  end

  def test_appending_prompt_command_is_fine
    File.write(File.join(@dir, ".bashrc"), "PROMPT_COMMAND=\"$PROMPT_COMMAND; y\"\n")
    refute_includes report(@env.merge("SHELL" => "/bin/bash")), "warning"
  end

  def test_not_the_recorded_tty_names_both_ttys
    log = File.join(@dir, "b.jsonl")
    File.write(log, "")
    out = report(@env.merge("OOPS_SESSION" => log, "OOPS_TTY" => "/dev/ttys001"), tty: "/dev/ttys009")
    assert_includes out, "this terminal: not the recorded tty (this: /dev/ttys009, recorded: /dev/ttys001)\n"
    out = report(@env.merge("OOPS_SESSION" => log, "OOPS_TTY" => "/dev/ttys001"), tty: nil)
    assert_includes out, "this terminal: not the recorded tty (this: unknown, recorded: /dev/ttys001)\n"
  end

  def test_cli_doctor_on_the_recorded_pty_reports_recorded
    master, slave = PTY.open
    log = File.join(@dir, "b.jsonl")
    File.write(log, "")
    out = StringIO.new
    env = @env.merge("OOPS_SESSION" => log, "OOPS_TTY" => slave.path, "XDG_STATE_HOME" => File.join(@dir, "st"))
    assert_equal 0, Oops::CLI.run(["doctor"], env: env, stdin: slave, stdout: out, stderr: StringIO.new)
    assert_includes out.string, "this terminal: recorded\n"
  ensure
    slave&.close
    master&.close
  end

  def test_cli_doctor_exits_zero_and_prints
    out = StringIO.new
    status = Oops::CLI.run(["doctor"], env: @env, stdout: out, stderr: StringIO.new)
    assert_equal 0, status
    assert_includes out.string, "recording: no"
  end
end
