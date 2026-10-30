require "test_helper"
require "pty"

class TtyTest < Minitest::Test
  def test_name_of_a_pty_slave_is_its_device_path
    master, slave = PTY.open
    assert_equal slave.path, Oops::Tty.name(slave)
  ensure
    slave&.close
    master&.close
  end

  def test_name_of_a_non_tty_is_nil
    assert_nil Oops::Tty.name(StringIO.new)
    IO.pipe do |r, _w|
      assert_nil Oops::Tty.name(r)
    end
  end
end
