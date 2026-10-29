require "test_helper"

class PromptSpTest < Minitest::Test
  # What zsh writes with the default PROMPT_EOL_MARK (%B%S%#%s%b) on an
  # 80-column terminal: mark, 79 spaces, CR, one space, CR. Without the xenl
  # (xn) capability zsh writes one space less.
  DEFAULT_MARK = "\e[1m\e[7m%\e[27m\e[1m\e[0m".freeze

  def filler(mark: DEFAULT_MARK, width: 1, columns: 80, xenl: true)
    "#{mark}#{' ' * (columns - width - (xenl ? 0 : 1))}\r#{' ' * width}\r"
  end

  def strip(text) = Oops::PromptSp.strip(text.b)

  def test_output_without_newline_keeps_its_last_line
    assert_equal "foo".b, strip("foo#{filler}")
  end

  def test_output_with_newline
    assert_equal "bar\r\n".b, strip("bar\r\n#{filler}")
  end

  def test_empty_output
    assert_equal "".b, strip(filler)
  end

  def test_terminal_without_xn_capability
    assert_equal "foo".b, strip("foo#{filler(xenl: false)}")
  end

  def test_empty_mark
    assert_equal "foo".b, strip("foo#{filler(mark: '', width: 0)}")
  end

  def test_custom_colored_mark
    assert_equal "foo".b, strip("foo#{filler(mark: "\e[31m⏎\e[0m")}")
  end

  def test_wide_mark
    assert_equal "foo".b, strip("foo#{filler(mark: "\u{1f51a}", width: 2)}")
  end

  def test_narrow_terminal
    assert_equal "foo".b, strip("foo#{filler(columns: 20)}")
  end

  def test_other_output_is_untouched
    ["foo", "foo\r\n", "50%\r100%\r\n", "spin  \r \r", "x\r#{' ' * 10}\r", "a\r\r"].each do |text|
      assert_equal text.b, strip(text), text.inspect
    end
  end

  def test_mark_wider_than_the_last_line_is_not_a_filler
    text = "\r\n#{' ' * 79}\r \r"
    assert_equal text.b, strip(text)
  end

  def test_long_runs_of_spaces_stay_fast
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    strip(" " * 1_000_000)
    strip("#{' ' * 1_000_000}x\r \r")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  end
end
