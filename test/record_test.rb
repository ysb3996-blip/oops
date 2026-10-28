require "test_helper"

class RecordTest < Minitest::Test
  def test_round_trip_binary_output
    r = Oops::Record.new(seq: 1, cmd: "ls", cwd: "/", started_at: 1, ended_at: 2, exit: 0,
                         output: "\e[31mx\xff".b, dropped_bytes: 0, fullscreen: false)
    line = r.to_json_line
    assert line.end_with?("\n")
    back = Oops::Record.from_json_line(line)
    assert_equal r, back
    assert_equal Encoding::ASCII_8BIT, back.output.encoding
  end

  def test_from_json_line_without_trailing_newline
    r = Oops::Record.new(seq: 2, cmd: "x", output: "hi".b)
    assert_equal r.output, Oops::Record.from_json_line(r.to_json_line.chomp).output
  end

  def test_malformed_line_raises_parse_error
    assert_raises(Oops::Record::ParseError) { Oops::Record.from_json_line("{not json\n") }
    assert_raises(Oops::Record::ParseError) { Oops::Record.from_json_line("[1,2]\n") }
    assert_raises(Oops::Record::ParseError) { Oops::Record.from_json_line("{\"output\":\"!!!\"}\n") }
  end

  def test_parse_error_is_standard_error
    assert Oops::Record::ParseError < StandardError
  end

  def test_oops_self
    assert Oops::Record.new(cmd: "oops err --github").oops_self?
    assert Oops::Record.new(cmd: "/opt/x/exe/oops err").oops_self?
    refute Oops::Record.new(cmd: "oopsie").oops_self?
  end
end
