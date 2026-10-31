# Security policy

English | [日本語](SECURITY.ja.md)

oops records your shell session and handles text that may contain secrets. If you find a way for that to go wrong, please tell us privately first.

## Supported versions

| Version | Supported |
|---|---|
| Latest 0.x release on RubyGems | Yes |
| Older releases | No, please upgrade |

## What counts as a security issue

- A secret in a format oops says it masks (see "Configuration" in the README) that is copied unmasked.
- Session logs, or their directory, created with looser permissions than `0600` for files and `0700` for the directory.
- The recorder (`oops record`) doing anything beyond its documented behavior: sending data anywhere, running commands on its own, or writing outside the state directory.
- Program output that can pause or resume recording, or otherwise control oops, without the user asking for it.
- The config file or a custom `clipboard:` command being able to run code it should not.

A secret in a format oops does not claim to know is not a vulnerability: masking is pattern based and the README says so. Ask for the pattern in a regular issue instead (see [issue #15](https://github.com/ysb3996-blip/oops/issues/15)).

## How to report

Use GitHub's private vulnerability reporting: [open a draft advisory](https://github.com/ysb3996-blip/oops/security/advisories/new). Only the maintainer can see it. Please do not open a public issue or pull request for a security problem.

In the report, **never paste a real secret or a session log**. Replace secrets with made-up values of the same shape (for example `sk-live-XXXXXXXXXXXXXXXX`), and describe the log line instead of attaching the file. Session logs hold the raw, unmasked output of every recorded command.

## What to expect

- An acknowledgement within 7 days.
- A fix in a patch release, with the change listed in the CHANGELOG. You will be credited there unless you ask not to be.
- The advisory is published after the fix is released.
