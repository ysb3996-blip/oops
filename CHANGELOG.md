# Changelog

## 0.1.0 - Unreleased

First version.

- `oops`, `oops N` and `oops err` copy the last command(s) and their output to the clipboard as a Markdown code block.
- `--github`, `--tail`, `--head` and `--show-secrets` options.
- Secrets (tokens, keys, emails, URL credentials, public IPv4 addresses, passwords given as command-line options) are masked by default, in the command line as well as the output.
- Config file with a replace table, extra secret patterns and a clipboard override.
- zsh and bash support through `oops init zsh|bash`, recorded by a small pty relay (`oops record`).
- `oops pause`, `oops resume` and `oops doctor`.
