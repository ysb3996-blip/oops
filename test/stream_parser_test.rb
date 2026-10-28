require "test_helper"

class StreamParserTest < Minitest::Test
  def setup
    @records = []
    @p = Oops::StreamParser.new(max_bytes: 100) { |r| @records << r }
  end

  def start(seq, cmd: "c") = Oops::Marker.start(seq: seq, started_at: 1, cwd: "/", cmd: cmd)
  def fin(seq, exit: 0) = Oops::Marker.end(seq: seq, exit: exit)

  # --- tests from the task brief ---

  def test_basic_record_and_marker_stripping
    fwd = @p.feed("prompt$ #{start(1)}hello\n#{fin(1, exit: 3)}prompt$ ")
    assert_equal "prompt$ hello\nprompt$ ", fwd
    assert_equal 1, @records.size
    assert_equal ["c", "hello\n", 3, 0, false],
                 @records[0].to_h.values_at(:cmd, :output, :exit, :dropped_bytes, :fullscreen)
  end

  def test_marker_split_across_feeds_is_not_forwarded
    m = start(1)
    a = m[0, 9]
    b = m[9..]
    assert_equal "", @p.feed(a)
    assert_equal "out", @p.feed("#{b}out")
    @p.feed(fin(1))
    assert_equal "out", @records[0].output
  end

  def test_output_over_cap_keeps_tail_and_counts_dropped
    @p.feed(start(1))
    @p.feed("a" * 150)
    @p.feed("b" * 50)
    @p.feed(fin(1, exit: 1))
    r = @records[0]
    assert_equal 100, r.output.bytesize
    assert r.output.end_with?("b" * 50)
    assert_equal 100, r.dropped_bytes
    assert_equal 1, r.exit
  end

  def test_fullscreen_span_omitted_but_forwarded
    fwd = @p.feed("#{start(1)}pre\e[?1049hVIMVIM\e[?1049lpost#{fin(1)}")
    assert_includes fwd, "VIMVIM"
    assert_equal "pre[full-screen app output omitted]\npost", @records[0].output
    assert @records[0].fullscreen
  end

  def test_pause_drops_everything_until_resume
    @p.feed(Oops::Marker.pause)
    assert_predicate @p, :paused?
    @p.feed("#{start(1)}secret#{fin(1)}")
    assert_empty @records
    @p.feed(Oops::Marker.resume)
    refute_predicate @p, :paused?
    @p.feed("#{start(2)}ok#{fin(2)}")
    assert_equal ["ok"], @records.map(&:output)
  end

  def test_finish_emits_unfinished_with_nil_exit
    @p.feed("#{start(1)}partial")
    @p.finish
    assert_nil @records[0].exit
    assert_equal "partial", @records[0].output
  end

  def test_bytes_outside_commands_are_forwarded_not_stored
    assert_equal "zzz", @p.feed("zzz")
    assert_empty @records
  end

  # --- forwarding and marker extraction ---

  def test_record_fields
    @p.feed(Oops::Marker.start(seq: 4, started_at: 1_700_000_000, cwd: "/tmp/x", cmd: "make test"))
    @p.feed("out")
    before = Time.now.to_i
    @p.feed(fin(4, exit: 2))
    r = @records[0]
    assert_equal [4, "make test", "/tmp/x", 1_700_000_000, 2, "out", 0, false],
                 r.to_h.values_at(:seq, :cmd, :cwd, :started_at, :exit, :output, :dropped_bytes, :fullscreen)
    assert_operator r.ended_at, :>=, before
    assert_equal Encoding::BINARY, r.output.encoding
  end

  def test_feed_returns_binary_string
    out = @p.feed("héllo")
    assert_equal Encoding::BINARY, out.encoding
    assert_equal "héllo".b, out
  end

  def test_held_back_prefix_that_is_not_a_marker_is_emitted_later
    assert_equal "abc", @p.feed("abc\e_oo")
    assert_equal "\e_oops!x".b, @p.feed("ps!x")
  end

  def test_trailing_escape_is_held_then_released
    assert_equal "a", @p.feed("a\e")
    assert_equal "\e[0mb", @p.feed("[0mb")
  end

  def test_held_back_body_aborted_by_other_escape
    assert_equal "", @p.feed("\e_oops;start;1")
    assert_equal "\e_oops;start;1\e[0mtext", @p.feed("\e[0mtext")
  end

  def test_held_back_body_is_bounded
    big = "#{Oops::Marker::PREFIX}#{'a' * 70_000}"
    assert_equal big, @p.feed(big)
  end

  def test_held_back_body_is_bounded_across_small_feeds
    fwd = +"".b
    fwd << @p.feed(Oops::Marker::PREFIX)
    70.times { fwd << @p.feed("a" * 1000) }
    assert_operator fwd.bytesize, :>, 65_000
    fwd << @p.finish
    assert_equal "#{Oops::Marker::PREFIX}#{'a' * 70_000}", fwd
  end

  def test_foreign_apc_passes_through
    foreign = "\e_tmux;hello\e\\"
    fwd = @p.feed("#{start(1)}#{foreign}x#{fin(1)}")
    assert_equal "#{foreign}x", fwd
    assert_equal "#{foreign}x", @records[0].output
  end

  def test_malformed_oops_marker_is_stripped_and_ignored
    fwd = @p.feed("a\e_oops;bogus;;\e\\b\e_oops;end;x;y\e\\c\e_oops;\e\\d")
    assert_equal "abcd", fwd
    assert_empty @records
  end

  def test_garbage_never_raises
    rng = Random.new(42)
    pieces = [start(1), fin(1), Oops::Marker.pause, Oops::Marker.resume, "\e", "\e_", "\e_oops;",
              "\e\\", "\e[?1049h", "\e[?1049l", "\e[?47"]
    stream = Array.new(2000) { rng.rand < 0.3 ? pieces.sample(random: rng) : rng.bytes(rng.rand(1..20)) }.join
    one = Oops::StreamParser.new(max_bytes: 100) { nil }
    whole = one.feed(stream) + one.finish
    many = Oops::StreamParser.new(max_bytes: 100) { nil }
    split = feed_in_random_pieces(many, stream, rng)
    assert_equal whole, split
  end

  # --- command state ---

  def test_end_with_mismatched_seq_is_ignored
    @p.feed("#{start(5)}a#{fin(4)}b")
    assert_empty @records
    @p.feed(fin(5))
    assert_equal([[5, "ab"]], @records.map { |r| [r.seq, r.output] })
  end

  def test_end_without_open_command_is_ignored
    assert_equal "x", @p.feed("#{fin(1)}x")
    assert_empty @records
  end

  def test_start_while_open_closes_previous_with_nil_exit
    @p.feed("#{start(1, cmd: 'first')}one#{start(2, cmd: 'second')}two#{fin(2, exit: 0)}")
    assert_equal([["first", "one", nil], ["second", "two", 0]],
                 @records.map { |r| [r.cmd, r.output, r.exit] })
  end

  def test_pause_drops_open_command
    @p.feed("#{start(1)}a")
    @p.feed(Oops::Marker.pause)
    @p.feed("b")
    @p.feed(Oops::Marker.resume)
    @p.feed(fin(1))
    @p.finish
    assert_empty @records
  end

  def test_markers_while_paused_are_stripped_from_forwarded_bytes
    fwd = @p.feed("#{Oops::Marker.pause}a#{start(1)}b#{fin(1)}c#{Oops::Marker.resume}d")
    assert_equal "abcd", fwd
    assert_empty @records
  end

  def test_finish_returns_held_bytes
    @p.feed("#{start(1)}out\e_oo")
    held = @p.finish
    assert_equal "\e_oo", held
    assert_equal Encoding::BINARY, held.encoding
    assert_equal "out\e_oo", @records[0].output
  end

  def test_finish_without_command_or_hold
    assert_equal "", @p.finish
    assert_empty @records
  end

  # --- full-screen spans ---

  def test_all_alt_screen_forms
    @p.feed("#{start(1)}a\e[?47hX\e[?47lb\e[?1047hY\e[?1047lc#{fin(1)}")
    omitted = "[full-screen app output omitted]\n"
    assert_equal "a#{omitted}b#{omitted}c", @records[0].output
  end

  def test_fullscreen_sequences_split_across_feeds
    fwd = +"".b
    fwd << @p.feed("#{start(1)}pre\e[?10")
    fwd << @p.feed("49hVIM\e[?1")
    fwd << @p.feed("049")
    fwd << @p.feed("lpost#{fin(1)}")
    assert_equal "pre\e[?1049hVIM\e[?1049lpost", fwd
    assert_equal "pre[full-screen app output omitted]\npost", @records[0].output
  end

  def test_partial_alt_screen_prefix_that_is_not_one_is_stored
    @p.feed("#{start(1)}a\e[?10")
    @p.feed("0hb#{fin(1)}")
    assert_equal "a\e[?100hb", @records[0].output
    refute @records[0].fullscreen
  end

  def test_partial_alt_screen_prefix_at_end_of_command_is_stored
    @p.feed("#{start(1)}a\e[?104#{fin(1)}")
    assert_equal "a\e[?104", @records[0].output
  end

  def test_end_inside_fullscreen_span_closes_it
    @p.feed("#{start(1)}a\e[?1049hTUI#{fin(1)}")
    @p.feed("#{start(2)}b#{fin(2)}")
    assert_equal ["a[full-screen app output omitted]\n", "b"], @records.map(&:output)
    assert_equal [true, false], @records.map(&:fullscreen)
  end

  def test_fullscreen_outside_command_is_not_recorded
    fwd = @p.feed("\e[?1049hX\e[?1049l#{start(1)}y#{fin(1)}")
    assert_equal "\e[?1049hX\e[?1049ly", fwd
    assert_equal "y", @records[0].output
    refute @records[0].fullscreen
  end

  # --- chunk boundaries ---

  def sample_stream
    [
      "prompt$ \e_tmux;foreign\e\\",
      Oops::Marker.start(seq: 1, started_at: 10, cwd: "/home/ü", cmd: "ls 世界"),
      "héllo 世界\n\e[31mred\e[0m\n",
      "\e[?1049hTUI SCREEN\e[?1049l",
      "after\e_oops!not a marker\n\e[?10x\n",
      Oops::Marker.end(seq: 1, exit: 2),
      "prompt$ \e_oops;garbage\e\\",
      Oops::Marker.pause,
      Oops::Marker.start(seq: 2, started_at: 11, cwd: "/", cmd: "secret"),
      "hidden",
      Oops::Marker.end(seq: 2, exit: 0),
      Oops::Marker.resume,
      Oops::Marker.start(seq: 3, started_at: 12, cwd: "/", cmd: "tail"),
      "絵文字🎉 tail\e_oo"
    ].join.b
  end

  def run_stream(pieces)
    records = []
    parser = Oops::StreamParser.new(max_bytes: 1000) { |r| records << r }
    fwd = +"".b
    pieces.each { |piece| fwd << parser.feed(piece) }
    fwd << parser.finish
    [fwd, records.map { |r| r.to_h.except(:ended_at) }]
  end

  def test_whole_stream_expected_result
    fwd, records = run_stream([sample_stream])
    expected_fwd = "prompt$ \e_tmux;foreign\e\\héllo 世界\n\e[31mred\e[0m\n\e[?1049hTUI SCREEN\e[?1049l" \
                   "after\e_oops!not a marker\n\e[?10x\nprompt$ hidden絵文字🎉 tail\e_oo"
    assert_equal expected_fwd.b, fwd
    assert_equal 2, records.size
    assert_equal({ seq: 1, cmd: "ls 世界", cwd: "/home/ü", started_at: 10, exit: 2,
                   output: "héllo 世界\n\e[31mred\e[0m\n[full-screen app output omitted]\n" \
                           "after\e_oops!not a marker\n\e[?10x\n".b,
                   dropped_bytes: 0, fullscreen: true }, records[0])
    assert_equal({ seq: 3, cmd: "tail", cwd: "/", started_at: 12, exit: nil,
                   output: "絵文字🎉 tail\e_oo".b, dropped_bytes: 0, fullscreen: false }, records[1])
  end

  def test_one_byte_at_a_time_matches_whole
    stream = sample_stream
    assert_equal run_stream([stream]), run_stream(stream.each_char.to_a)
  end

  def test_every_two_way_split_matches_whole
    stream = sample_stream
    whole = run_stream([stream])
    (1...stream.bytesize).each do |i|
      assert_equal whole, run_stream([stream.byteslice(0, i), stream.byteslice(i..)]), "split at #{i}"
    end
  end

  def test_random_splits_match_whole
    stream = sample_stream
    whole = run_stream([stream])
    rng = Random.new(7)
    20.times do
      pieces = []
      pos = 0
      while pos < stream.bytesize
        n = rng.rand(1..12)
        pieces << stream.byteslice(pos, n)
        pos += n
      end
      assert_equal whole, run_stream(pieces)
    end
  end

  def test_tail_buffer_matches_naive_tail
    rng = Random.new(3)
    buf = Oops::StreamParser::TailBuffer.new(1000)
    naive = +"".b
    500.times do
      piece = rng.bytes(rng.rand(0..1200))
      buf << piece
      naive << piece
      assert_equal naive.byteslice(-[naive.bytesize, 1000].min..), buf.to_s
      assert_equal [naive.bytesize - 1000, 0].max, buf.dropped
    end
  end

  # --- performance ---

  def test_large_stream_is_linear_and_bounded
    records = []
    parser = Oops::StreamParser.new { |r| records << r }
    # Colored compiler-style output: an escape sequence every few bytes.
    line = "\e[1;31merror\e[0m: \e[33mfile.rb\e[0m:12 \e[?25lmsg\e[?25h\n"
    chunk = (line * (4096 / line.bytesize)).b
    chunk << ("x" * (4096 - chunk.bytesize))
    assert_equal 4096, chunk.bytesize
    count = 50 * 1024 * 1024 / chunk.bytesize
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    parser.feed(start(1))
    forwarded = 0
    count.times { forwarded += parser.feed(chunk).bytesize }
    parser.feed(fin(1))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_equal count * 4096, forwarded
    r = records[0]
    assert_equal 1_048_576, r.output.bytesize
    assert_equal (count * 4096) - 1_048_576, r.dropped_bytes
    assert r.output.end_with?(chunk)
    assert_operator elapsed, :<, 5.0
  end

  private

  def feed_in_random_pieces(parser, stream, rng)
    out = +"".b
    pos = 0
    while pos < stream.bytesize
      n = rng.rand(1..64)
      out << parser.feed(stream.byteslice(pos, n))
      pos += n
    end
    out << parser.finish
  end
end
