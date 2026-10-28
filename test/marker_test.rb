require "test_helper"

class MarkerTest < Minitest::Test
  def strip(marker)
    marker.delete_prefix("\e_").delete_suffix("\e\\")
  end

  def test_start_round_trip
    m = Oops::Marker.start(seq: 7, started_at: 1_700_000_000, cwd: "/a;b", cmd: "echo 'x;y'\nls")
    assert m.start_with?("\e_oops;start;7;1700000000;")
    assert m.end_with?("\e\\")
    h = Oops::Marker.parse(strip(m))
    assert_equal({ kind: :start, seq: 7, started_at: 1_700_000_000, cwd: "/a;b", cmd: "echo 'x;y'\nls" }, h)
  end

  def test_end_round_trip = assert_equal({ kind: :end, seq: 7, exit: 130 }, Oops::Marker.parse("oops;end;7;130"))
  def test_pause_resume = assert_equal(:pause, Oops::Marker.parse("oops;pause")[:kind])
  def test_garbage_returns_nil = assert_nil Oops::Marker.parse("oops;what;;")

  def test_constants
    assert_equal "\e_oops;", Oops::Marker::PREFIX
    assert_equal "\e\\", Oops::Marker::SUFFIX
    assert_predicate Oops::Marker::PREFIX, :frozen?
    assert_predicate Oops::Marker::SUFFIX, :frozen?
  end

  def test_exact_bytes
    assert_equal "\e_oops;pause\e\\", Oops::Marker.pause
    assert_equal "\e_oops;resume\e\\", Oops::Marker.resume
    assert_equal "\e_oops;end;3;0\e\\", Oops::Marker.end(seq: 3, exit: 0)
    assert_equal "\e_oops;start;1;2;Lw==;bHM=\e\\",
                 Oops::Marker.start(seq: 1, started_at: 2, cwd: "/", cmd: "ls")
  end

  def test_pause_resume_round_trip
    assert_equal({ kind: :pause }, Oops::Marker.parse(strip(Oops::Marker.pause)))
    assert_equal({ kind: :resume }, Oops::Marker.parse(strip(Oops::Marker.resume)))
  end

  def test_end_round_trip_via_builder
    assert_equal({ kind: :end, seq: 9, exit: 255 }, Oops::Marker.parse(strip(Oops::Marker.end(seq: 9, exit: 255))))
  end

  def test_garbage_inputs_return_nil
    [
      nil, "", "oops", "oops;", "oops;;", "x;start;1;2;Lw==;bHM=", "oops;start", "oops;start;1;2;Lw==",
      "oops;start;1;2;Lw==;bHM=;extra", "oops;start;a;2;Lw==;bHM=", "oops;start;1;b;Lw==;bHM=",
      "oops;start;-1;2;Lw==;bHM=", "oops;start;1;-2;Lw==;bHM=", "oops;start;1;2;!!!;bHM=",
      "oops;start;1;2;Lw==;not base64", "oops;start;1;2;Lw;bHM=", "oops;end", "oops;end;1", "oops;end;x;0",
      "oops;end;1;x", "oops;end;1;", "oops;end;-1;0", "oops;end;1;0;9", "oops;pause;1", "oops;resume;",
      "oops;PAUSE", "oops;start;1;2;Lw==;bHM=\n", "\xff\xfe\x00junk".b, "oops;\xff;1".b, 42, :oops
    ].each { |input| assert_nil Oops::Marker.parse(input), "expected nil for #{input.inspect}" }
  end

  def test_empty_cwd_and_cmd
    h = Oops::Marker.parse(strip(Oops::Marker.start(seq: 0, started_at: 0, cwd: "", cmd: "")))
    assert_equal({ kind: :start, seq: 0, started_at: 0, cwd: "", cmd: "" }, h)
  end

  def test_command_with_special_characters_round_trips
    [";;;", "a;b;c", "line1\nline2\r\n", "echo 日本語 ✓", "printf '\\e[0m'", "\e_oops;pause\e\\"].each do |cmd|
      h = Oops::Marker.parse(strip(Oops::Marker.start(seq: 1, started_at: 2, cwd: "/tmp/ü", cmd: cmd)))
      assert_equal cmd, h[:cmd]
      assert_equal "/tmp/ü", h[:cwd]
      assert_equal Encoding::UTF_8, h[:cmd].encoding
    end
  end

  def test_100kb_command_round_trips
    cmd = "echo #{'あ;' * 50_000}\n"
    h = Oops::Marker.parse(strip(Oops::Marker.start(seq: 1, started_at: 2, cwd: "/", cmd: cmd)))
    assert_operator cmd.bytesize, :>, 100_000
    assert_equal cmd, h[:cmd]
  end

  def test_encoded_fields_have_no_raw_newline_or_semicolon
    m = Oops::Marker.start(seq: 1, started_at: 2, cwd: "/a;b\n", cmd: "x;y\nz#{'q' * 1000}")
    body = strip(m)
    refute_includes body, "\n"
    fields = body.split(";", -1)
    assert_equal 6, fields.size
    fields[4..].each { |f| assert_match(%r{\A[A-Za-z0-9+/]*={0,2}\z}, f) }
  end

  def test_invalid_utf8_is_scrubbed
    h = Oops::Marker.parse(strip(Oops::Marker.start(seq: 1, started_at: 2, cwd: "/", cmd: "a\xffb".b)))
    assert_equal "a�b", h[:cmd]
    assert_predicate h[:cmd], :valid_encoding?
  end

  def test_binary_payload_encoding_is_accepted
    assert_equal({ kind: :end, seq: 1, exit: 2 }, Oops::Marker.parse("oops;end;1;2".b))
  end
end
