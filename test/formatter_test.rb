require "test_helper"

class FormatterTest < Minitest::Test
  def rec(cmd:, out:, exit: 0)
    Oops::Record.new(seq: 1, cmd: cmd, cwd: "/", started_at: 0, ended_at: 0, exit: exit,
                     output: out.b, dropped_bytes: 0, fullscreen: false)
  end

  def fmt(**) = Oops::Formatter.new(config: Oops::Config.load("/none"), home: "/Users/takeuchi", **)

  def test_default_shape_with_exit
    r = fmt.format([rec(cmd: "bundle exec rspec", out: "....F\n\n", exit: 1)])
    assert_equal "```\n$ bundle exec rspec\n....F\n(exit 1)\n```\n", r.text
  end

  def test_exit_zero_omitted
    assert_equal "```\n$ ls\na\n```\n", fmt.format([rec(cmd: "ls", out: "a\n")]).text
  end

  def test_multiline_command_indented
    assert_includes fmt.format([rec(cmd: "cat <<EOF\nhi\nEOF", out: "hi\n")]).text, "$ cat <<EOF\n  hi\n  EOF\n"
  end

  def test_fence_grows_when_output_has_backticks
    t = fmt.format([rec(cmd: "cat x", out: "```\n")]).text
    assert t.start_with?("````\n")
    assert t.end_with?("````\n")
  end

  def test_home_replaced_and_secret_masked_in_command_and_output
    r = fmt.format([rec(cmd: "export TOKEN=abc123 && cd /Users/takeuchi/dev",
                        out: "/Users/takeuchi/dev ghp_#{'a' * 36}\n")])
    assert_includes r.text, "$ export TOKEN=[secret] && cd ~/dev\n~/dev [secret]\n"
    assert_equal 2, r.masked_count
    assert_equal "export TOKEN=[secret] && cd ~/dev", r.command_line
  end

  def test_show_secrets_disables_masking_and_replace
    cfg = Oops::Config.load("/none")
    cfg.replace["takeuchi"] = "dev"
    r = Oops::Formatter.new(config: cfg, home: "/Users/takeuchi", show_secrets: true)
                       .format([rec(cmd: "echo takeuchi", out: "ghp_#{'a' * 36}\n")])
    assert_includes r.text, "echo takeuchi"
    assert_equal 0, r.masked_count
  end

  def test_replace_table_longest_first
    cfg = Oops::Config.load("/none")
    cfg.replace.merge!("MacBook-Pro" => "laptop", "takeuchi" => "dev")
    assert_includes Oops::Formatter.new(config: cfg).format([rec(cmd: "x", out: "takeuchi@MacBook-Pro\n")]).text,
                    "dev@laptop"
  end

  def test_tail_and_head
    out = "#{(1..100).map { |i| "l#{i}" }.join("\n")}\n"
    assert_includes fmt(tail: 2).format([rec(cmd: "x", out: out)]).text, "... 98 lines omitted ...\nl99\nl100\n"
    assert_includes fmt(head: 1, tail: 1).format([rec(cmd: "x", out: out)]).text,
                    "l1\n... 98 lines omitted ...\nl100\n"
  end

  def test_omitted_count_uses_thousands_separator
    out = "#{(1..3001).map { 'l' }.join("\n")}\n"
    assert_includes fmt(tail: 1).format([rec(cmd: "x", out: out)]).text, "... 3,000 lines omitted ..."
  end

  def test_multiple_records_in_one_fence
    t = fmt.format([rec(cmd: "a", out: "1\n"), rec(cmd: "b", out: "2\n", exit: 2)]).text
    assert_equal "```\n$ a\n1\n\n$ b\n2\n(exit 2)\n```\n", t
  end

  def test_github_short
    t = fmt(github: true).format([rec(cmd: "ls", out: "a\n", exit: 1)]).text
    assert_equal "```console\n$ ls\na\n(exit 1)\n```\n", t
  end

  def test_github_long_is_collapsed
    out = "#{(1..31).map { 'l' }.join("\n")}\n"
    t = fmt(github: true).format([rec(cmd: "ls", out: out, exit: 1)]).text
    assert t.start_with?("<details>\n<summary><code>$ ls</code> — exit 1, 31 lines</summary>\n\n```console\n")
    assert t.end_with?("```\n\n</details>\n")
  end

  def test_invalid_utf8_scrubbed
    assert_includes fmt.format([rec(cmd: "x", out: "a\xffb\n")]).text, "a�b"
  end

  def test_lines_counted_after_formatting
    assert_equal 2, fmt.format([rec(cmd: "x", out: "a\nb\n\n\n")]).lines
  end

  def test_github_multiple_records_get_own_blocks
    long = "#{(1..31).map { 'l' }.join("\n")}\n"
    t = fmt(github: true).format([rec(cmd: "a", out: "1\n"), rec(cmd: "b", out: long)]).text
    assert t.start_with?("```console\n$ a\n1\n```\n\n<details>\n<summary><code>$ b</code> — 31 lines</summary>")
    assert t.end_with?("```\n\n</details>\n")
  end

  def test_github_summary_is_escaped_and_single_line
    long = "#{(1..31).map { 'l' }.join("\n")}\n"
    t = fmt(github: true).format([rec(cmd: "echo '<a&b>'\nls", out: long)]).text
    assert_includes t, "<summary><code>$ echo '&lt;a&amp;b&gt;' ls</code> — 31 lines</summary>"
    assert_includes t, "$ echo '<a&b>'\n  ls\n"
  end

  def test_empty_output_shows_only_command
    r = fmt.format([rec(cmd: "cd foo", out: "")])
    assert_equal "```\n$ cd foo\n```\n", r.text
    assert_equal 0, r.lines
  end

  def test_nil_exit_is_like_zero
    assert_equal "```\n$ ls\na\n```\n", fmt.format([rec(cmd: "ls", out: "a\n", exit: nil)]).text
  end

  def test_fullscreen_record_is_plain
    r = Oops::Record.new(seq: 1, cmd: "vim x", cwd: "/", started_at: 0, ended_at: 0, exit: 0,
                         output: "[fullscreen app output not captured]\n".b, dropped_bytes: 0, fullscreen: true)
    assert_equal "```\n$ vim x\n[fullscreen app output not captured]\n```\n", fmt.format([r]).text
  end

  def test_home_prefix_only_at_path_boundary
    t = fmt.format([rec(cmd: "ls /Users/takeuchi2 /Users/takeuchi", out: "/Users/takeuchi2/x\n")]).text
    assert_includes t, "$ ls /Users/takeuchi2 ~\n/Users/takeuchi2/x\n"
  end

  def test_ansi_stripped_from_output
    assert_includes fmt.format([rec(cmd: "x", out: "\e[31mred\e[0m\n")]).text, "\nred\n"
  end

  def test_large_single_line_is_fast
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fmt.format([rec(cmd: "x", out: "#{'a' * 1_000_000}\n")])
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
  end
end
