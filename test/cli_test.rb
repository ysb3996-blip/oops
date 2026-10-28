require "test_helper"
class CLITest < Minitest::Test
  def test_version_prints_version_and_exits_zero
    out = StringIO.new
    status = Oops::CLI.run(["--version"], stdout: out, stderr: StringIO.new)
    assert_equal 0, status
    assert_equal "oops #{Oops::VERSION}\n", out.string
  end

  def test_unknown_option_exits_two
    err = StringIO.new
    status = Oops::CLI.run(["--bogus"], stdout: StringIO.new, stderr: err)
    assert_equal 2, status
    assert_match(/oops: /, err.string)
  end
end
