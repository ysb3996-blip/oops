# Changelog

English | [日本語](CHANGELOG.ja.md)

## 0.4.1 - 2026-11-04

- Fixed: a closed tab's log is no longer kept forever when its process id is reused by another process. A process that started after the log was last written is not the tab that wrote it ([#58](https://github.com/ysb3996-blip/oops/issues/58)).
- Changed: a tab that stays open now drops commands older than `retention_days` from its own log when a command finishes, at most once an hour ([#59](https://github.com/ysb3996-blip/oops/issues/59)).
- bash in Ghostty: when Ghostty injected its shell integration into the outer shell, the recorded shell now loads it again, as zsh and fish already did. The line the README asked bash users to add is no longer needed there ([#50](https://github.com/ysb3996-blip/oops/issues/50)).
- Changed: the line that stands in for a full-screen app's output names the command when the line holds one command, e.g. `[git: full-screen output omitted]` for `git log` through a pager ([#45](https://github.com/ysb3996-blip/oops/issues/45)).

## 0.4.0 - 2026-11-03

- `--print` / `-p`: write the formatted text to stdout instead of the clipboard, so SSH sessions, containers and scripts can pipe it ([#40](https://github.com/ysb3996-blip/oops/issues/40)). Contributed by [@ShahadatTest](https://github.com/ShahadatTest) in [#52](https://github.com/ysb3996-blip/oops/pull/52).

## 0.3.0 - 2026-11-02

- `oops clear` deletes the logs of closed tabs, and `oops clear --all` also empties the current tab's log ([#42](https://github.com/ysb3996-blip/oops/issues/42)).
- Changed: logs of closed tabs are now deleted 7 days after their last command, when a tab starts recording. Set `retention_days` in the config to change the number of days, or `retention_days: false` to keep them until the 50 MB limit ([#42](https://github.com/ysb3996-blip/oops/issues/42)).
- fish support: add `oops init fish | source` to `~/.config/fish/config.fish` ([#9](https://github.com/ysb3996-blip/oops/issues/9)).
- `oops.plugin.zsh` for zsh plugin managers (antidote, zinit, Oh My Zsh, ...). It runs oops from the cloned repository, so no gem install is needed.
- Homebrew tap: `brew install ysb3996-blip/oops/oops`. The formula runs oops with Homebrew's Ruby.

## 0.2.0 - 2026-11-01

- `oops status` prints `recording`, `paused` or `off` on one line and exits 0 only when recording, so a prompt or script can show whether this shell is recorded.
- `--time` option: adds the local time each command started as a `# 2026-10-31 19:30:09 +09:00` line before `$ command`, and to the `--github` summary.
- `--output-only` option: leaves out the `$ command` line and copies only the output and `(exit N)`.
- `-n N` option for `oops` and `oops err`: `oops -n 3` is the same as `oops 3`, and `oops err -n 2` copies the last 2 failed commands (oldest first), skipping over successful ones. Contributed by [@ricky9408](https://github.com/ricky9408) in [#22](https://github.com/ysb3996-blip/oops/pull/22).
- Email masking no longer hides versioned names such as `/opt/homebrew/opt/mysql@8.4` or `go@1.27`: the last part of the domain must now be letters, like a real top-level domain ([#24](https://github.com/ysb3996-blip/oops/issues/24)).

## 0.1.0 - 2026-10-30

First version.

- `oops`, `oops N` and `oops err` copy the last command(s) and their output to the clipboard as a Markdown code block.
- `--github`, `--tail`, `--head` and `--show-secrets` options.
- Secrets (tokens, keys, emails, URL credentials, public IPv4 addresses, passwords given as command-line options) are masked by default, in the command line as well as the output.
- Config file with a replace table, extra secret patterns and a clipboard override.
- zsh and bash support through `oops init zsh|bash`, recorded by a small pty relay (`oops record`).
- `oops pause`, `oops resume` and `oops doctor`.
