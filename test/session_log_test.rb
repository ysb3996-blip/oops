require "test_helper"
require "tmpdir"

class SessionLogTest < Minitest::Test
  def rec(seq, cmd: "c#{seq}", exit: 0, out: "o#{seq}")
    Oops::Record.new(seq: seq, cmd: cmd, cwd: "/", started_at: 0, ended_at: 0, exit: exit,
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

  def test_last_on_missing_file_is_empty
    with_log { |log| assert_equal [], log.last(3) }
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
      Oops::SessionLog.rotate!(d, max_bytes: 25, alive: ->(pid) { pid == 1 })
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
      Oops::SessionLog.rotate!(d, max_bytes: 5, alive: ->(pid) { pid == 2 })
      assert_equal %w[20260102-000000-2.jsonl other.jsonl], Dir.children(d).sort
    end
  end
end
