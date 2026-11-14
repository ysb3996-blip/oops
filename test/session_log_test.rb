require "test_helper"
require "tmpdir"

class SessionLogTest < Minitest::Test
  def rec(seq, cmd: "c#{seq}", exit: 0, out: "o#{seq}", ended: 0)
    Oops::Record.new(seq: seq, cmd: cmd, cwd: "/", started_at: ended, ended_at: ended, exit: exit,
                     output: out.b, dropped_bytes: 0, fullscreen: false)
  end

  def with_log
    Dir.mktmpdir { |d| yield Oops::SessionLog.new("#{d}/s.jsonl"), d }
  end

  # Counts bytes requested from disk by each_backward.
  class CountingLog < Oops::SessionLog
    attr_reader :bytes_read

    private

    def read_chunk(io, offset, length)
      @bytes_read = @bytes_read.to_i + length
      super
    end
  end

  def test_append_sets_private_mode
    with_log do |log|
      log.append(rec(1))
      assert_equal 0o600, File.stat(log.path).mode & 0o777
    end
  end

  def test_append_raises_when_directory_missing
    log = Oops::SessionLog.new("/nonexistent-oops-dir/s.jsonl")
    assert_raises(SystemCallError) { log.append(rec(1)) }
  end

  def test_append_caps_the_log_keeping_the_newest_records
    Dir.mktmpdir do |d|
      log = Oops::SessionLog.new("#{d}/s.jsonl", max_bytes: 2000)
      line = rec(1, out: "x" * 100).to_json_line.bytesize
      sizes = (1..60).map do |i|
        log.append(rec(i, out: "x" * 100))
        File.size(log.path)
      end
      assert_operator sizes.max, :<=, 2000
      assert_operator sizes.max, :>, 2000 - line, "the cap is used, not cut far below it"
      kept = log.last(100).map(&:seq)
      assert_equal 60, kept.last
      assert_equal (kept.first..60).to_a, kept, "newest records kept, in order"
      assert_equal 0o600, File.stat(log.path).mode & 0o777
      assert_equal ["s.jsonl"], Dir.children(d)
    end
  end

  def test_cap_failure_does_not_raise_or_lose_the_record
    skip "root ignores directory permissions" if Process.uid.zero?
    Dir.mktmpdir do |d|
      log = Oops::SessionLog.new("#{d}/s.jsonl", max_bytes: 1000)
      log.append(rec(1, out: "x" * 200))
      log.append(rec(2, out: "x" * 200))
      File.chmod(0o500, d)
      log.append(rec(3, out: "y" * 200))
      assert_operator File.size(log.path), :>, 1000
      assert_equal [1, 2, 3], log.last(5).map(&:seq)
    ensure
      File.chmod(0o700, d)
    end
  end

  def test_cap_keeps_the_newest_record_even_when_it_alone_is_too_big
    Dir.mktmpdir do |d|
      log = Oops::SessionLog.new("#{d}/s.jsonl", max_bytes: 100)
      log.append(rec(1, out: "x" * 200))
      log.append(rec(2, out: "y" * 200))
      assert_equal [2], log.last(5).map(&:seq)
    end
  end

  def test_last_skips_oops_and_unfinished
    with_log do |log|
      log.append(rec(1))
      log.append(rec(2, cmd: "oops"))
      log.append(rec(3, exit: nil))
      log.append(rec(4))
      assert_equal [1, 4], log.last(2).map(&:seq)
    end
  end

  def test_last_returns_oldest_first_and_limits
    with_log do |log|
      5.times { |i| log.append(rec(i)) }
      assert_equal [3, 4], log.last(2).map(&:seq)
    end
  end

  def test_last_containing_counts_only_matching_records
    with_log do |log|
      log.append(rec(1, cmd: "make test"))
      log.append(rec(2, cmd: "ls"))
      log.append(rec(3, cmd: "oops grep make"))
      log.append(rec(4, cmd: "make lint"))
      log.append(rec(5, cmd: "pwd"))
      assert_equal [4], log.last(1, containing: "MAKE").map(&:seq)
      assert_equal [1, 4], log.last(5, containing: "make").map(&:seq)
      assert_equal [], log.last(1, containing: "rake")
    end
  end

  def test_last_on_missing_file_is_empty
    with_log { |log| assert_equal [], log.last(3) }
  end

  def test_last_failed_only_limits_failures_and_returns_oldest_first
    with_log do |log|
      log.append(rec(1, exit: 1))
      log.append(rec(2, exit: 2))
      log.append(rec(3))
      log.append(rec(4, exit: 3))
      log.append(rec(5, exit: nil))
      log.append(rec(6, cmd: "oops err -n 2", exit: 1))
      log.append(rec(7, exit: "1"))
      assert_equal [2, 4], log.last(2, failed_only: true).map(&:seq)
      assert_equal [1, 2, 4], log.last(10, failed_only: true).map(&:seq)
    end
  end

  def test_last_failed_only_on_missing_file_or_without_failures_is_empty
    with_log do |log|
      assert_empty log.last(2, failed_only: true)
      log.append(rec(1))
      assert_empty log.last(2, failed_only: true)
    end
  end

  def test_last_failed_only_stops_reading_when_count_is_reached
    Dir.mktmpdir do |dir|
      log = CountingLog.new("#{dir}/s.jsonl")
      200.times { |i| log.append(rec(i, out: "x" * 1000, exit: i.even? ? 1 : 0)) }
      assert_equal [196, 198], log.last(2, failed_only: true).map(&:seq)
      assert_operator log.bytes_read, :<=, Oops::SessionLog::CHUNK_SIZE + 1
    end
  end

  def test_last_failed_skips_successes
    with_log do |log|
      log.append(rec(1, exit: 1))
      log.append(rec(2))
      assert_equal 1, log.last_failed.seq
    end
  end

  def test_last_failed_ignores_unfinished_and_oops
    with_log do |log|
      log.append(rec(1, exit: 2))
      log.append(rec(2, exit: nil))
      log.append(rec(3, cmd: "oops", exit: 1))
      assert_equal 1, log.last_failed.seq
    end
  end

  def test_last_failed_nil_when_none
    with_log do |log|
      log.append(rec(1))
      assert_nil log.last_failed
    end
  end

  def test_backward_read_crosses_chunk_boundary
    with_log do |log|
      200.times { |i| log.append(rec(i, out: "x" * 1000)) }
      assert_operator File.size(log.path), :>, 64 * 1024
      assert_equal [199, 198, 197], log.last(3).reverse.map(&:seq)
      seqs = []
      log.each_backward { |r| seqs << r.seq }
      assert_equal (0..199).to_a.reverse, seqs
    end
  end

  def test_line_spanning_multiple_chunks
    with_log do |log|
      log.append(rec(1))
      log.append(rec(2, out: "y" * (300 * 1024)))
      log.append(rec(3))
      got = log.last(3)
      assert_equal [1, 2, 3], got.map(&:seq)
      assert_equal 300 * 1024, got[1].output.bytesize
    end
  end

  def test_corrupt_middle_line_is_skipped
    with_log do |log, _d|
      log.append(rec(1))
      File.open(log.path, "ab") { |f| f.write("garbage{{{\n\n") }
      log.append(rec(2))
      assert_equal [1, 2], log.last(5).map(&:seq)
    end
  end

  def test_truncated_last_line_is_skipped
    with_log do |log|
      log.append(rec(1))
      File.open(log.path, "ab") { |f| f.write(rec(2).to_json_line.chomp[0, 20]) }
      assert_equal [1], log.last(5).map(&:seq)
    end
  end

  def test_each_backward_stops_on_stop
    with_log do |log|
      5.times { |i| log.append(rec(i)) }
      seen = []
      log.each_backward do |r|
        seen << r.seq
        :stop if seen.size == 2
      end
      assert_equal [4, 3], seen
    end
  end

  def test_last_one_reads_little_of_a_large_file
    Dir.mktmpdir do |d|
      log = CountingLog.new("#{d}/s.jsonl")
      40.times { |i| log.append(rec(i, out: "z" * (512 * 1024))) }
      assert_operator File.size(log.path), :>, 20 * 1024 * 1024
      assert_equal [39], log.last(1).map(&:seq)
      assert_operator log.bytes_read, :<, 2 * 1024 * 1024
    end
  end

  def test_pause_flag
    with_log do |log|
      refute log.paused?
      log.pause!
      assert log.paused?
      assert_equal 0o600, File.stat("#{log.path}.paused").mode & 0o777
      log.resume!
      refute log.paused?
      log.resume!
    end
  end

  def test_new_path
    path = Oops::SessionLog.new_path("/d", pid: 42, now: Time.new(2026, 1, 2, 3, 4, 5))
    assert_equal "/d/20260102-030405-42.jsonl", path
  end

  def test_rotate_deletes_oldest_dead_sessions_only
    Dir.mktmpdir do |d|
      %w[20260101-000000-1 20260102-000000-2 20260103-000000-3].each { |n| File.write("#{d}/#{n}.jsonl", "x" * 10) }
      Oops::SessionLog.rotate!(d, max_bytes: 25, alive: ->(pid, _) { pid == 1 })
      assert_equal %w[20260101-000000-1.jsonl 20260103-000000-3.jsonl], Dir.children(d).sort
    end
  end

  def test_rotate_removes_siblings_and_ignores_odd_names
    Dir.mktmpdir do |d|
      File.write("#{d}/20260101-000000-1.jsonl", "x" * 10)
      File.write("#{d}/20260101-000000-1.jsonl.paused", "")
      File.write("#{d}/20260101-000000-1.jsonl.status", "")
      File.write("#{d}/other.jsonl", "x" * 100)
      File.write("#{d}/20260102-000000-2.jsonl", "x" * 10)
      Oops::SessionLog.rotate!(d, max_bytes: 5, alive: ->(pid, _) { pid == 2 })
      assert_equal %w[20260102-000000-2.jsonl other.jsonl], Dir.children(d).sort
    end
  end

  def test_rotate_deletes_dead_sessions_older_than_max_age
    Dir.mktmpdir do |d|
      now = Time.now
      { "20260101-000000-1" => 10, "20260102-000000-2" => 10, "20260103-000000-3" => 1 }.each do |name, days|
        File.write("#{d}/#{name}.jsonl", "x")
        File.utime(now - (days * 86_400), now - (days * 86_400), "#{d}/#{name}.jsonl")
      end
      File.write("#{d}/20260101-000000-1.jsonl.status", "ok")
      Oops::SessionLog.rotate!(d, max_age: 7 * 86_400, now: now, alive: ->(pid, _) { pid == 1 })
      assert_equal %w[20260101-000000-1.jsonl 20260101-000000-1.jsonl.status 20260103-000000-3.jsonl],
                   Dir.children(d).sort
    end
  end

  def test_rotate_without_max_age_keeps_old_logs_under_the_size_cap
    Dir.mktmpdir do |d|
      File.write("#{d}/20260101-000000-1.jsonl", "x")
      File.utime(Time.now - (400 * 86_400), Time.now - (400 * 86_400), "#{d}/20260101-000000-1.jsonl")
      Oops::SessionLog.rotate!(d, alive: ->(_, _) { false })
      assert_equal %w[20260101-000000-1.jsonl], Dir.children(d)
    end
  end

  def test_clear_deletes_every_dead_session_and_reports_the_count
    Dir.mktmpdir do |d|
      %w[20260101-000000-1 20260102-000000-2 20260103-000000-3].each { |n| File.write("#{d}/#{n}.jsonl", "x") }
      File.write("#{d}/20260102-000000-2.jsonl.paused", "")
      File.write("#{d}/other.jsonl", "x")
      assert_equal 2, Oops::SessionLog.clear!(d, alive: ->(pid, _) { pid == 3 })
      assert_equal %w[20260103-000000-3.jsonl other.jsonl], Dir.children(d).sort
    end
  end

  def test_clear_without_a_sessions_dir_removes_nothing
    assert_equal 0, Oops::SessionLog.clear!("/nonexistent/oops/sessions")
  end

  def test_empty_keeps_the_file_and_the_pause_flag
    with_log do |log|
      log.append(rec(1))
      log.pause!
      log.empty!
      assert_equal 0, File.size(log.path)
      assert log.paused?
      assert_equal [], log.last(1)
    end
  end

  def test_rotate_and_clear_pass_the_time_the_log_was_last_written
    Dir.mktmpdir do |d|
      File.write("#{d}/20260102-030405-7.jsonl", "x")
      written = Time.at(1_800_000_000)
      File.utime(written, written, "#{d}/20260102-030405-7.jsonl")
      seen = []
      alive = lambda do |pid, written_at|
        seen << [pid, written_at]
        true
      end
      Oops::SessionLog.rotate!(d, max_bytes: 0, alive: alive)
      Oops::SessionLog.clear!(d, alive: alive)
      assert_equal [[7, written]] * 2, seen
    end
  end

  def test_odd_log_names_do_not_break_rotate_or_clear
    Dir.mktmpdir do |d|
      gone = Process.spawn("true")
      Process.wait(gone)
      ["20261399-999999-#{gone}", "20260101-000000-99999999999999999999"].each do |name|
        File.write("#{d}/#{name}.jsonl", "x")
      end
      Oops::SessionLog.rotate!(d, max_bytes: 0)
      assert_equal [], Dir.children(d)
    end
  end

  def test_session_alive_needs_a_live_process_that_started_before_the_log
    opened = Time.at(1_800_000_000)
    check = lambda do |live, started|
      Oops::SessionLog.session_alive?(42, opened, alive: ->(_) { live }, started_at: ->(_) { started })
    end
    assert check.call(true, opened - 3600), "the recorder started before it named the log"
    assert check.call(true, opened + 2), "a few seconds of slack"
    refute check.call(true, opened + 60), "a reused process id belongs to a newer process"
    assert check.call(true, nil), "an unknown start time keeps the log"
    refute check.call(false, opened - 3600), "the process is gone"
  end

  def test_process_started_at_reads_the_start_time_of_a_process
    started = Oops::SessionLog.process_started_at(Process.pid)
    assert_kind_of Time, started
    assert_operator started, :<=, Time.now
  end

  def test_process_started_at_is_nil_for_a_process_that_is_gone
    pid = Process.spawn("true")
    Process.wait(pid)
    assert_nil Oops::SessionLog.process_started_at(pid)
  end

  def test_append_drops_records_older_than_max_age
    Dir.mktmpdir do |d|
      now = Time.at(1_800_000_000)
      log = Oops::SessionLog.new("#{d}/s.jsonl", max_age: 86_400)
      File.write(log.path, [rec(1, ended: now.to_i - (3 * 86_400)), rec(2, ended: now.to_i - 3600)]
                             .map(&:to_json_line).join)
      log.append(rec(3, ended: now.to_i), now: now)
      assert_equal [2, 3], log.last(5).map(&:seq)
    end
  end

  def test_append_checks_the_age_of_records_at_most_once_an_hour
    Dir.mktmpdir do |d|
      t0 = Time.at(1_800_000_000)
      log = Oops::SessionLog.new("#{d}/s.jsonl", max_age: 100)
      log.append(rec(1, ended: t0.to_i), now: t0)
      log.append(rec(2, ended: t0.to_i + 1800), now: t0 + 1800)
      assert_equal [1, 2], log.last(5).map(&:seq)
      log.append(rec(3, ended: t0.to_i + 3600), now: t0 + 3600)
      assert_equal [3], log.last(5).map(&:seq)
    end
  end

  def test_append_expires_a_log_whose_first_line_is_unreadable
    Dir.mktmpdir do |d|
      now = Time.at(1_800_000_000)
      log = Oops::SessionLog.new("#{d}/s.jsonl", max_age: 86_400)
      File.write(log.path, "not json\n#{rec(1, ended: now.to_i - (3 * 86_400)).to_json_line}")
      log.append(rec(2, ended: now.to_i), now: now)
      assert_equal [2], log.last(5).map(&:seq)
    end
  end

  def test_append_without_max_age_keeps_old_records
    with_log do |log|
      log.append(rec(1, ended: 0))
      log.append(rec(2, ended: Time.now.to_i))
      assert_equal [1, 2], log.last(5).map(&:seq)
    end
  end
end
