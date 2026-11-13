require "test_helper"

class PickerTest < Minitest::Test
  def record(cmd, output: "", exit: 0, started_at: Time.new(2026, 11, 13, 19, 30).to_i)
    Oops::Record.new(seq: 1, cmd: cmd, cwd: "/", started_at: started_at, ended_at: started_at, exit: exit,
                     output: output, dropped_bytes: 0, fullscreen: false)
  end

  def formatter = Oops::Formatter.new(config: Oops::Config.new("/nonexistent/config.yml"), home: "/home/u")

  def test_menu_numbers_oldest_first_and_aligns_the_details
    menu = Oops::Picker.menu([record("bundle exec rake", output: "F\n" * 84, exit: 1),
                              record("git status", output: "x\n")], formatter)
    assert_equal ["1  $ bundle exec rake  (exit 1, 84 lines, 19:30)",
                  "2  $ git status        (exit 0, 1 line, 19:30)"], menu
  end

  def test_menu_masks_secrets_and_shortens_long_or_multi_line_commands
    menu = Oops::Picker.menu([record("export GITHUB_TOKEN=ghp_#{'a' * 36}"),
                              record("echo #{'x' * 80}"),
                              record("for f in *\ndo echo $f\ndone")], formatter)
    assert_includes menu[0], "$ export GITHUB_TOKEN=[secret]"
    refute_includes menu.join, "ghp_"
    assert_includes menu[1], "$ echo #{'x' * 52}..."
    assert_includes menu[2], "$ for f in * ..."
  end

  def test_menu_without_a_start_time_leaves_the_time_out
    assert_equal ["1  $ ls  (exit 0, 0 lines)"], Oops::Picker.menu([record("ls", started_at: nil)], formatter)
  end

  def test_parse_numbers_ranges_and_commas_sorted_without_repeats
    assert_equal [1, 3], Oops::Picker.parse("3 1\n", 5)
    assert_equal [2, 3, 4, 5], Oops::Picker.parse("2-4,5 4", 5)
    assert_equal [2], Oops::Picker.parse("  2  ", 5)
  end

  def test_parse_rejects_empty_unknown_and_out_of_range_answers
    {
      nil => "nothing picked.", "\n" => "nothing picked.", "a" => "not a number: a",
      "0" => "no command numbered 0 (1-3)", "4" => "no command numbered 4 (1-3)",
      "2-9" => "no command numbered 9 (1-3)", "3-1" => "backwards range: 3-1", "-1" => "not a number: -1"
    }.each do |input, message|
      error = assert_raises(Oops::Picker::Invalid, input.inspect) { Oops::Picker.parse(input, 3) }
      assert_equal message, error.message
    end
  end
end
