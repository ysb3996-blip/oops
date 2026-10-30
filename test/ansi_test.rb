require "test_helper"

class AnsiTest < Minitest::Test
  def test_removes_sgr_colors
    assert_equal "ok", Oops::Ansi.strip("\e[32mok\e[0m")
  end

  def test_removes_osc_with_bel_and_st
    assert_equal "ab", Oops::Ansi.strip("a\e]0;title\ab\e]52;c;xx\e\\")
  end

  def test_removes_apc
    assert_equal "ab", Oops::Ansi.strip("a\e_oops;start;1\e\\b")
  end

  def test_unterminated_dcs_apc_pm_sos_end_at_the_next_escape
    assert_equal "a\nkept\n", Oops::Ansi.strip("a\n\ePstray\e[31mkept\n")
    assert_equal "akept", Oops::Ansi.strip("a\e_oops;x\e[0mkept")
    assert_equal "ab", Oops::Ansi.strip("a\eXsos\e^pm\e\\b")
    assert_equal "x", Oops::Ansi.strip("x\ePnever ends")
  end

  def test_carriage_return_keeps_last_state_of_line
    assert_equal "100%\ndone", Oops::Ansi.strip("10%\r50%\r100%\ndone")
  end

  def test_backspace_deletes_previous_char
    assert_equal "ab", Oops::Ansi.strip("abc\b")
  end

  def test_clear_screen_sequences_removed
    assert_equal "x", Oops::Ansi.strip("\e[H\e[2J\e[3Jx")
  end

  def test_single_char_escapes_leave_no_stray_characters
    # ESC 7 / ESC 8 save and restore the cursor, ESC = / ESC > switch the keypad.
    assert_equal "abcd", Oops::Ansi.strip("a\e7b\e8c\e=d\e>")
  end

  def test_cursor_forward_becomes_spaces
    assert_equal "Accessing workspace:", Oops::Ansi.strip("Accessing\e[1Cworkspace:")
    assert_equal "a   b", Oops::Ansi.strip("a\e[3Cb")
    assert_equal "a b", Oops::Ansi.strip("a\e[Cb")
  end

  def test_cursor_forward_is_capped
    assert_equal "a#{' ' * 200}b", Oops::Ansi.strip("a\e[99999Cb")
  end

  def test_cursor_column_jump_separates_words
    # Full-screen UIs place every word with ESC [ n G instead of printing spaces.
    assert_equal "Accessing workspace:", Oops::Ansi.strip("\e[2G\e[1mAccessing\e[12Gworkspace:\e[22m")
    assert_equal "a b c", Oops::Ansi.strip("a\e[5Gb\e[9Gc")
  end

  def test_cursor_column_jump_at_line_start_or_after_space_adds_nothing
    assert_equal "  x", Oops::Ansi.strip("  \e[3Gx")
    assert_equal "x\ny", Oops::Ansi.strip("x\n\e[2Gy")
    assert_equal "a", Oops::Ansi.strip("\e[1Ga")
  end

  def test_crlf_is_single_newline
    assert_equal "a\nb\n", Oops::Ansi.strip("a\r\nb\r\n")
  end

  def test_binary_input_with_invalid_utf8_does_not_raise
    input = "a\xFF\e[1mb\e[0m".b
    assert_equal "a\xFFb".b, Oops::Ansi.strip(input)
  end

  def test_backspace_deletes_whole_multibyte_char
    assert_equal "あ", Oops::Ansi.strip("あい\b")
  end
end
