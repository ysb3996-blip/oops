# Changelog

English | [日本語](CHANGELOG.ja.md)

## Unreleased

- `oops status` prints `recording`, `paused` or `off` on one line and exits 0 only when recording, so a prompt or script can show whether this shell is recorded.
- `--time` option: adds the local time each command started as a `# 2026-10-31 19:30:09 +09:00` line before `$ command`, and to the `--github` summary.
- `--output-only` option: leaves out the `$ command` line and copies only the output and `(exit N)`.
- `-n N` option for `oops` and `oops err`: `oops -n 3` is the same as `oops 3`, and `oops err -n 2` copies the last 2 failed commands (oldest first), skipping over successful ones. Contributed by [@ricky9408](https://github.com/ricky9408) in [#22](https://github.com/ysb3996-blip/oops/pull/22).

## 0.1.0 - 2026-10-30

First version.

- `oops`, `oops N` and `oops err` copy the last command(s) and their output to the clipboard as a Markdown code block.
- `--github`, `--tail`, `--head` and `--show-secrets` options.
- Secrets (tokens, keys, emails, URL credentials, public IPv4 addresses, passwords given as command-line options) are masked by default, in the command line as well as the output.
- Config file with a replace table, extra secret patterns and a clipboard override.
- zsh and bash support through `oops init zsh|bash`, recorded by a small pty relay (`oops record`).
- `oops pause`, `oops resume` and `oops doctor`.
