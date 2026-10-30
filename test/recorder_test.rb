require "test_helper"
require "pty"

# Lets a test make PTY.open fail without redefining it (which warns).
module FailingPtyOpen
  def open(*, &)
    raise Errno::ENXIO, "no pty" if Thread.current[:oops_fail_pty_open]

    super
  end
end
PTY.singleton_class.prepend(FailingPtyOpen)

class RecorderTest < Minitest::Test
  FailingLog = Struct.new(:calls) do
    def append(_record)
      self.calls += 1
      raise Errno::ENOSPC, "disk full"
    end
  end

  def marked(seq, cmd, output, exit_status)
    start = Oops::Marker.start(seq: seq, started_at: 1, cwd: "/", cmd: cmd)
    "#{start}#{output}#{Oops::Marker.end(seq: seq, exit: exit_status)}"
  end

  def test_filter_with_failing_log_still_forwards_output
    errors = []
    log = FailingLog.new(0)
    filter = Oops::Recorder::OutputFilter.new(log: log, on_error: errors.method(:push))
    assert_equal "a\nb\n", filter.feed("a\n#{marked(1, 'x', "b\n", 0)}")
    assert_equal "c\n", filter.feed(marked(2, "y", "c\n", 1))
    assert_equal 1, log.calls
    assert_equal ["No space left on device - disk full"], errors
  end

  def test_filter_appends_records_to_the_log
    records = []
    log = Object.new
    log.define_singleton_method(:append) { |r| records << r }
    filter = Oops::Recorder::OutputFilter.new(log: log, on_error: ->(m) { flunk m })
    assert_equal "out\n", filter.feed(marked(3, "make", "out\n", 2))
    assert_equal([[3, "make", 2, "out\n"]], records.map { [_1.seq, _1.cmd, _1.exit, _1.output] })
  end

  def test_filter_forwards_raw_bytes_once_the_parser_fails
    errors = []
    filter = Oops::Recorder::OutputFilter.new(log: nil, on_error: errors.method(:push))
    filter.instance_variable_get(:@parser).define_singleton_method(:feed) { |_| raise "bug" }
    assert_equal "one\e_oops;pause\e\\", filter.feed("one\e_oops;pause\e\\")
    assert_equal "two", filter.feed("two")
    assert_equal "", filter.finish
    assert_equal ["stream parser failed: RuntimeError: bug"], errors
  end

  def test_finish_returns_held_bytes
    filter = Oops::Recorder::OutputFilter.new(log: nil, on_error: ->(m) { flunk m })
    assert_equal "x", filter.feed("x\e_oo")
    assert_equal "\e_oo", filter.finish
  end

  def with_recorder(env: {}, stdin: StringIO.new)
    Dir.mktmpdir do |dir|
      err = StringIO.new
      rec = Oops::Recorder.new(%w[sh -i], env: { "XDG_STATE_HOME" => dir }.merge(env), stdin: stdin,
                                          stdout: StringIO.new, stderr: err)
      execs = []
      rec.define_singleton_method(:exec_shell) do |extra|
        execs << extra
        0
      end
      yield rec, execs, err, dir
    end
  end

  def test_same_tty_as_oops_tty_execs_the_shell_directly
    _master, slave = PTY.open
    with_recorder(env: { "OOPS_TTY" => slave.path }, stdin: slave) do |rec, execs, _err, dir|
      assert_equal 0, rec.run
      assert_equal [{}], execs
      refute Dir.exist?("#{dir}/oops"), "no session must be created"
    end
  end

  def test_pty_failure_execs_the_shell_with_recording_disabled
    with_recorder do |rec, execs, err, dir|
      begin
        Thread.current[:oops_fail_pty_open] = true
        assert_equal 0, rec.run
      ensure
        Thread.current[:oops_fail_pty_open] = nil
      end
      assert_equal [{ "OOPS_DISABLE" => "1" }], execs
      assert_match(/\Aoops: recording disabled: .*no pty/, err.string)
      assert_empty Dir.glob("#{dir}/oops/sessions/*"), "the unused session log is removed"
    end
  end

  def test_unexpected_relay_error_warns_once_and_the_relay_goes_on
    err = StringIO.new
    stdin_r, stdin_w = IO.pipe
    rec = Oops::Recorder.new(%w[sh], env: {}, stdin: stdin_r, stdout: StringIO.new, stderr: err)
    output_r, output_w = IO.pipe
    wake_r, wake_w = IO.pipe
    output_w.write("x") # keeps the fake pty readable
    pid = Process.spawn("true")
    { master: output_r, wake_r: wake_r, pid: pid,
      filter: Oops::Recorder::OutputFilter.new(log: nil, on_error: ->(m) { flunk m }) }.each do |k, v|
      rec.instance_variable_set(:"@#{k}", v)
    end
    calls = 0
    rec.define_singleton_method(:read_output) do
      calls += 1
      raise "boom" if calls <= 2

      @output_open = false
    end
    rec.send(:relay)
    assert_equal 3, calls
    assert_equal "oops: warning: unexpected relay error (RuntimeError: boom); continuing\n", err.string
  ensure
    Process.wait(pid) if pid && !rec.instance_variable_get(:@status)
    [stdin_r, stdin_w, output_r, output_w, wake_r, wake_w].each { |io| io&.close }
  end

  def test_stdin_hangup_on_a_terminal_hangs_up_the_shell
    stdin = Object.new
    stdin.define_singleton_method(:tty?) { true }
    stdin.define_singleton_method(:readpartial) { |_| raise Errno::EIO }
    rec = Oops::Recorder.new(%w[sh], env: {}, stdin: stdin, stdout: StringIO.new, stderr: StringIO.new)
    pid = Process.spawn("sleep", "10")
    rec.instance_variable_set(:@pid, pid)
    rec.instance_variable_set(:@input, +"".b)
    rec.send(:read_input)
    refute rec.instance_variable_get(:@stdin_open)
    assert_equal Signal.list["HUP"], Process.wait2(pid)[1].termsig
    pid = nil
  ensure
    begin
      Process.kill("KILL", pid) if pid
      Process.wait(pid) if pid
    rescue SystemCallError
      nil
    end
  end

  def test_shell_that_cannot_start_falls_back_to_exec
    Dir.mktmpdir do |dir|
      err = StringIO.new
      rec = Oops::Recorder.new(["/nonexistent/shell"], env: { "XDG_STATE_HOME" => dir }, stdin: StringIO.new,
                                                       stdout: StringIO.new, stderr: err)
      execs = []
      rec.define_singleton_method(:exec_shell) do |extra|
        execs << extra
        0
      end
      assert_equal 0, rec.run
      assert_equal [{ "OOPS_DISABLE" => "1" }], execs
      assert_match %r{oops: recording disabled: cannot run /nonexistent/shell}, err.string
    end
  end
end
