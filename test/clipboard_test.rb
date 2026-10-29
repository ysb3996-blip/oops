require_relative "test_helper"

class ClipboardTest < Minitest::Test
  def detect(setting = "auto", env: {}, which: ->(_) { true }, platform: "x86_64-linux", proc_version: "")
    Oops::Clipboard.detect(setting, env: env, which: which, platform: platform, proc_version: proc_version)
  end

  def test_macos_prefers_pbcopy = assert_equal "pbcopy", detect(platform: "arm64-darwin25").name
  def test_wsl_uses_clip_exe = assert_equal "clip.exe", detect(proc_version: "Linux version 5 microsoft-standard").name

  def test_wayland_then_x11
    assert_equal "wl-copy", detect(env: { "WAYLAND_DISPLAY" => "w" }).name
    assert_equal "xclip", detect(env: { "DISPLAY" => ":0" }).name
    assert_equal "xsel", detect(env: { "DISPLAY" => ":0" }, which: ->(c) { c != "xclip" }).name
  end

  def test_ssh_or_nothing_falls_back_to_osc52
    assert_equal "osc52", detect(env: { "SSH_TTY" => "/dev/pts/1" }, platform: "arm64-darwin25").name
    assert_equal "osc52", detect(which: ->(_) { false }).name
  end

  def test_setting_false_empty_nil_mean_auto
    ["false", "", nil].each do |s|
      assert_equal "pbcopy", detect(s, platform: "arm64-darwin25").name
    end
  end

  def test_explicit_names
    assert_equal "osc52", detect("osc52", platform: "arm64-darwin25").name
    assert_equal "xsel", detect("xsel").name
    assert_equal "pbcopy", detect("pbcopy", which: ->(_) { false }).name
  end

  def test_custom_command_string_copies_via_shell
    Dir.mktmpdir do |d|
      backend = detect("cat > #{d}/c")
      assert_equal "cat", backend.name
      backend.copy("hi")
      assert_equal "hi", File.read("#{d}/c")
    end
  end

  def test_command_failure_raises_with_stderr
    err = assert_raises(Oops::Clipboard::Error) { Oops::Clipboard::Shell.new("echo boom >&2; exit 3").copy("x") }
    assert_includes err.message, "boom"
    assert_includes err.message, "echo"
  end

  def test_missing_binary_raises
    cmd = Oops::Clipboard::Command.new("nope", ["oops-no-such-binary-xyz"])
    err = assert_raises(Oops::Clipboard::Error) { cmd.copy("x") }
    assert_includes err.message, "nope"
  end

  def test_daemonizing_command_does_not_hang
    Dir.mktmpdir do |d|
      backend = Oops::Clipboard::Shell.new("cat > #{d}/c; sleep 3 &")
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      backend.copy("hi")
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 2
      assert_equal "hi", File.read("#{d}/c")
    end
  end

  def test_command_with_utf16le_encoding
    Dir.mktmpdir do |d|
      Oops::Clipboard::Command.new("sh", ["sh", "-c", "cat > #{d}/c"], encoding: "UTF-16LE").copy("hé")
      assert_equal "hé".encode("UTF-16LE").b, File.binread("#{d}/c")
    end
  end

  def test_osc52_payload_written_to_tty
    io = StringIO.new
    Oops::Clipboard::Osc52.new(tty: io).copy("hi")
    assert_equal "\e]52;c;aGk=\a", io.string
  end

  def test_osc52_truncates_from_the_front_over_limit
    io = StringIO.new
    _, err = capture_io { Oops::Clipboard::Osc52.new(tty: io, max_bytes: 8).copy("abcdefghijkl") }
    assert io.string.end_with?("#{['jkl'].pack('m0')}\a")
    assert_includes err, "oops: warning: clipboard text truncated to fit OSC 52 limit"
  end

  def test_osc52_truncation_respects_utf8_boundary
    io = StringIO.new
    capture_io { Oops::Clipboard::Osc52.new(tty: io, max_bytes: 8).copy("aあいう") }
    payload = io.string[/\e\]52;c;(.*)\a/, 1].unpack1("m")
    assert_equal "いう", payload.force_encoding("UTF-8")
    assert_predicate payload, :valid_encoding?
  end

  def test_osc52_handles_invalid_utf8
    io = StringIO.new
    Oops::Clipboard::Osc52.new(tty: io).copy("a\xFFb".b)
    assert_equal "\e]52;c;#{["a\xFFb".b].pack('m0')}\a", io.string
  end

  def test_osc52_tty_open_failure_raises
    assert_raises(Oops::Clipboard::Error) { Oops::Clipboard::Osc52.new(tty: "/nonexistent-dir/tty").copy("x") }
  end
end
