# oops

English | [日本語](README.ja.md)

[![Gem Version](https://img.shields.io/gem/v/oops-cli)](https://rubygems.org/gems/oops-cli) [![CI](https://github.com/ysb3996-blip/oops/actions/workflows/ci.yml/badge.svg)](https://github.com/ysb3996-blip/oops/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![codecov](https://codecov.io/gh/ysb3996-blip/oops/graph/badge.svg)](https://codecov.io/gh/ysb3996-blip/oops) [![All Contributors](https://img.shields.io/github/all-contributors/ysb3996-blip/oops?color=ee8449)](#contributors)

Copy the last shell command and its output to the clipboard, ready to paste.

![Demo: a test fails, oops copies the command and its output, a comment line and pbpaste show what is on the clipboard; then cat .env, oops, and the API key is shown as [secret]](docs/demo.gif)

You ran a command and it failed. You want to show it to a chat assistant, a teammate on Slack, or a GitHub issue. Normally that means dragging to select the output, copying, pasting, and adding the code fences yourself. With oops it is two steps:

1. Type `oops` (or `oops err` for the last failed command).
2. Paste with Cmd-V.

What lands on your clipboard is a code block with the command, its output, and the exit code. Colors are stripped, and tokens, keys and email addresses are masked.

## Install

```sh
gem install oops-cli
```

Or with Homebrew:

```sh
brew install ysb3996-blip/oops/oops
```

The Homebrew formula runs oops with Homebrew's own Ruby, so it works even if an older Ruby comes first on your `PATH`.

Requires Ruby 3.3 or newer on macOS or Linux (WSL counts as Linux), and zsh, bash or fish. There are no runtime gem dependencies.

Checked by hand on macOS in Terminal.app, iTerm2, Ghostty and the VS Code integrated terminal. If it misbehaves in another terminal, please open an issue.

`gem install` puts oops into the Ruby that is active at that moment; each Ruby version has its own gems. With rbenv, asdf or mise, a tab that uses another Ruby gives a `command not found` error for `oops`, also when the shell starts. The fix that always works is to run `gem install oops-cli` again under the active Ruby (with rbenv, follow with `rbenv rehash`). Outside directories that pin a Ruby with `.ruby-version`, `.tool-versions` or `mise.toml`, you can instead set the Ruby you installed into as your global Ruby (for example `rbenv global 3.3.5`).

### With a zsh plugin manager

For zsh you can load oops as a plugin instead. It runs oops from the cloned repository, so there is no gem to install (Ruby 3.3 or newer is still needed), and the plugin replaces the rc line below.

```sh
# antidote: add to ~/.zsh_plugins.txt
ysb3996-blip/oops

# zinit: in ~/.zshrc, without `wait` (turbo mode)
zinit light ysb3996-blip/oops

# Oh My Zsh: clone, then add oops to plugins=(...) in ~/.zshrc
git clone https://github.com/ysb3996-blip/oops "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/oops"

# No plugin manager: clone, then add the source line to ~/.zshrc
git clone https://github.com/ysb3996-blip/oops ~/.oops
source ~/.oops/oops.plugin.zsh
```

- Load it right away, not deferred (zinit `wait`, zsh-defer). The plugin starts your shell again under the recorder, which should happen before the first prompt.
- The notes on where the line goes (below) apply to where the plugin is loaded. With powerlevel10k's instant prompt, the plugin has to be loaded above the instant prompt block, which plugin managers usually are not; use the rc line there.
- If the Ruby on `PATH` is too old, the shell prints `oops: ... init zsh failed (oops needs Ruby 3.3 or later); recording disabled` and starts as usual, without recording.
- Plugin managers update from the `main` branch, which can be ahead of the latest release.

## Set up your shell

Add one line to your rc file (`~/.zshrc` for zsh, `~/.bashrc` for bash; if you keep your bash setup in `~/.bash_profile` on macOS, put it there):

```sh
eval "$(oops init zsh)"    # zsh
eval "$(oops init bash)"   # bash
```

For fish, add this line to `~/.config/fish/config.fish`:

```fish
oops init fish | source
```

Then open a new tab. Existing tabs pick it up after `exec zsh` (or `exec bash`, `exec fish`).

Where to put the line matters:

- Put it **after** whatever puts the Ruby that has oops on your `PATH` (rbenv, asdf, mise, Homebrew `shellenv`, and so on). On macOS, login shells reset `PATH`, so if the line comes first, the system Ruby 2.6 may be picked and oops will not start. If oops cannot run, your shell still starts normally, just without recording.
- Put it **before** slow or noisy setup that you do not want to run twice (nvm, prompt themes, banners). The snippet starts your shell again under a small recorder (`oops record`, a pty relay), so anything above the line runs once in the outer shell and again in the inner one. Anything below it runs only in the inner shell.
- With powerlevel10k, put the line **above** the instant prompt block at the top of `~/.zshrc`. The instant prompt redirects the shell's input and output while the rest of `~/.zshrc` runs, and the snippet does nothing then (it only acts on a real terminal), so oops would silently not record. If a tab is not recorded although the line is in `~/.zshrc`, run `oops doctor`: it shows `recording: no`.
- In zsh the shell is restarted as a non-login shell, so setup that lives only in `~/.zlogin` is not applied to the recorded shell. Keep it in `~/.zprofile` or `~/.zshrc` (above the line). In bash, a login shell is restarted with `-l`, and in fish with `--login`.
- fish is restarted just before its first prompt, so all of `config.fish` runs in both the outer and the recorded shell, wherever the line is. (Starting it earlier would also catch `fish -i -c` and `fish -i script.fish`, which never show a prompt and must not be restarted.)

If something looks wrong, run `oops doctor`. It reports whether this tab is recorded, the shell and whether the hooks are loaded, which clipboard method will be used, the config file, the size of the session logs, and the Ruby version.

To turn oops off for one shell, start it with `OOPS_DISABLE=1` (for example `OOPS_DISABLE=1 zsh`). The snippet then does nothing.

## Usage

| Command | What it does |
|---|---|
| `oops` | Copy the last command and its output |
| `oops 3` / `oops -n 3` | Copy the last 3 commands (oldest first) as one code block |
| `oops err` | Copy the last command that exited non-zero, skipping over successful ones |
| `oops err -n 2` | Copy the last 2 failed commands (oldest first), skipping over successful ones |
| `oops init zsh` / `oops init bash` / `oops init fish` | Print the shell snippet (for `eval`, or `\| source` in fish) |
| `oops doctor` | Diagnose recording, hooks, clipboard, config and log size |
| `oops pause` / `oops resume` | Stop and restart recording. While paused, nothing is written to disk |
| `oops status` | Print `recording`, `paused` or `off` on one line, for scripts and prompts |
| `oops clear` / `oops clear --all` | Delete the logs of closed tabs; `--all` also empties this tab's log |
| `oops record -- <shell>` | Internal: runs a shell under the recorder. The snippet calls this |
| `oops --version`, `oops --help` | Version and usage |

Options for `oops`, `oops N` and `oops err`:

| Option | What it does |
|---|---|
| `-n N` | Copy the last N commands (with `err`, the last N failed commands) |
| `--github` | Format for a GitHub issue or PR comment |
| `--tail N` | Keep only the last N output lines |
| `--head N` | Keep only the first N output lines (with `--tail`, keeps both ends) |
| `--time` | Add the time each command started as a `# 2026-10-31 19:30:09 +09:00` line |
| `--output-only` | Leave out the `$ command` line and copy only the output |
| `-p`, `--print` | Write the text to stdout instead of the clipboard (no `copied:` line) |
| `--show-secrets` | Do not mask secrets and do not apply the replace table |

`N` must be a positive integer. Specify the command count once, either as a positional `N` or with `-n N`; combining them or repeating `-n` is a usage error. If fewer matching commands are available, oops copies those it finds. `-n` can be combined with the formatting options above.

`oops` never copies itself: if the previous command was `oops`, you get the command before it.

Exit codes: `0` copied (or printed with `--print`), `1` nothing copied (not recording, no command yet, no failed command, paused, or the clipboard command failed), `2` usage error.

### Default output

`oops` prints one line such as `copied: $ bundle exec rspec (5 lines, 2 secrets masked)` and puts this on the clipboard:

````
```
$ bundle exec rspec
....F

Failures:
  1) User#name returns full name
     expected "Taro Yamada", got "Taro"
(exit 1)
```
````

`(exit N)` appears only when the exit code is not 0. If the output itself contains a code fence, the block is fenced with four backticks instead.

### `--github`

Output of 30 lines or fewer becomes a `console` block, which GitHub highlights as a shell session:

````
```console
$ bundle exec rspec
....F
(exit 1)
```
````

Longer output is wrapped in a collapsible section whose summary shows the command, exit code and line count:

````
<details>
<summary><code>$ bundle exec rspec</code> — exit 1, 312 lines</summary>

```console
$ bundle exec rspec
...
(exit 1)
```

</details>
````

### `--tail` and `--head`

`oops --tail 50` keeps the last 50 lines of output and puts `... 2,950 lines omitted ...` before them. `--head 20` keeps the first 20 and puts the marker after. With both, the middle is replaced by one marker line. With `oops 3`, the limits apply to each command.

### `--time` and `--output-only`

`oops --time` puts the local time the command started on a `#` line before each `$ command`, and adds it to the `--github` summary. `oops --output-only` leaves out the `$ command` line and keeps the output and `(exit N)`; the `copied: $ ...` line on screen and the `--github` summary then show the exit code and line count without the command. Both can be combined with the other options:

````
```
# 2026-10-31 19:30:09 +09:00
....F
(exit 1)
```
````

### `oops status`

`oops status` prints `recording`, `paused` or `off` (this shell is not recorded, or its log was deleted) and exits `0` only when recording. It prints no error, so a prompt or script can call it, for example with a [starship custom module](https://starship.rs/config/#custom-commands). Each call starts Ruby, which takes roughly 0.1 to 0.2 seconds; `oops doctor` tells more when the answer is `off`.

## Configuration

Optional file at `${XDG_CONFIG_HOME:-~/.config}/oops/config.yml`:

```yaml
replace:            # plain string replacements applied when copying
  takeuchi: dev
  MacBook-Pro: laptop
secrets:            # extra regular expressions to mask
  - "sk_live_[A-Za-z0-9]+"
clipboard: auto     # auto | pbcopy | wl-copy | xclip | xsel | clip.exe | osc52 | any command (reads stdin)
retention_days: 7   # delete commands older than this many days; false keeps them
```

- Replacements and masking are applied at the moment you copy; the recorded log stays untouched, so a config change also affects earlier commands.
- `replace` keys are applied longest first and are case-sensitive.
- Unknown keys produce a warning and are ignored. A broken YAML file produces a warning and oops carries on without a config.
- With `clipboard: auto`, oops tries `pbcopy` on macOS, `clip.exe` on WSL, `wl-copy` on Wayland, `xclip` or `xsel` on X11, and falls back to the OSC 52 terminal escape sequence (also used over SSH). `oops doctor` shows which one it picked.
- `retention_days` (default 7) counts from the last time a closed tab wrote its log. Old logs are deleted when a tab starts recording. A tab that stays open also drops commands older than that from its own log when a command finishes (at most once an hour), so a tab that runs nothing keeps them until its next command. With `false`, logs stay until the 50 MB limit removes them.
- A custom `clipboard:` command runs in its own process group with a 5 second timeout, so it must not read from or configure the terminal (no password prompts, no `stty`); Ctrl-C during a copy does not reach it.

Built-in masking covers AWS access keys, GitHub, GitLab, Slack, npm, OpenAI/Anthropic (`sk-...`), Stripe and Google API tokens, Slack webhook URLs, JWTs, `Authorization` header values, private key blocks (also when the END line is missing), values assigned to names containing `key`, `token`, `secret`, `password`, `passwd` or `pwd`, passwords given as `--password <value>`, `curl -u user:pass`, `mysql -p<value>` or `docker login -p <value>`, email addresses, credentials inside URLs, and public IPv4 addresses (loopback and private ranges are left alone). It is applied to the command line as well as the output.

Masking is pattern based, so it is a safety net, not a guarantee: a secret in a format it does not know (a bare password printed on its own line, for example) is copied as it is. Read what you are about to paste, and add your own patterns under `secrets:` in the config file.

## How it works

![How oops works: a recorder sits between you and your shell, every command is written to a notebook on your disk, typing oops copies the last page with secrets hidden, and you paste it anywhere](docs/how-it-works.svg)

1. `oops init` prints a snippet that you `eval` from your rc file (`| source` in fish). In an interactive shell on a terminal that is not recorded yet, it restarts the shell under `oops record`.
2. `oops record` is a small Ruby pty relay: it passes your keystrokes and the shell's output through untouched and forwards window resizes to the shell.
3. Hooks in the shell (zsh `preexec`/`precmd`, bash `DEBUG` trap and `PROMPT_COMMAND`, fish `fish_preexec`/`fish_postexec` events) emit invisible APC markers around each command. The relay strips them, so your terminal never sees them.
4. For each finished command the relay appends one JSON line (command, directory, times, exit code, raw output) to a per-tab log under `${XDG_STATE_HOME:-~/.local/state}/oops/sessions/`. Output is capped at 1 MB per command (the tail is kept). Each tab's log is capped at 50 MB: when it passes that, it is rewritten to keep only its newest commands (down to about 37 MiB). When a tab starts recording, logs of closed tabs older than `retention_days` (7 by default) are deleted, and then the oldest of the rest until all logs together take at most 50 MB; logs of open tabs are never deleted, so several busy tabs can together use more. A tab counts as open while the process in its log name is running and started before the log was last written. An open tab also drops commands older than `retention_days` from its own log when a command finishes, at most once an hour.
5. `oops` reads the end of the current tab's log, cleans and masks the text, builds the code block and hands it to the clipboard. Nothing is ever re-run.

## Privacy and security

- The session logs hold the raw, **unmasked** output of every recorded command. Masking and the replace table are applied only when you copy. The logs live under `${XDG_STATE_HOME:-~/.local/state}/oops/sessions/`, readable only by you (mode 0600, directory 0700). With the default `retention_days` of 7, a closed tab's log is deleted once 7 days have passed since its last command (when another tab starts recording), and an open tab drops commands older than 7 days when it finishes a command. `oops clear` deletes the logs of closed tabs now, and `oops clear --all` also empties the current tab's log. To delete everything, including the logs of other open tabs, run `rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/oops"` (by default `rm -rf ~/.local/state/oops`). Use `oops pause` before showing secrets you do not want on disk.
- To report a security problem privately, see [SECURITY.md](SECURITY.md). Please do not open a public issue for it.
- Recorded output is untrusted: any program you run can print text that looks like oops's markers. oops therefore obeys a pause or resume marker only when it agrees with the flag file that `oops pause` and `oops resume` set, so output cannot silently pause recording. A program can still fake where a command starts and ends in the log, so check what you paste.

## Known limitations

- Each recorded tab keeps one Ruby process alive (about 17 MB).
- `sudo -s` or `su` that drops the environment starts a second, nested recording, so those commands are logged twice.
- Only the current tab is available. A tab you closed, or an earlier tab, cannot be retrieved.
- Via OSC 52 (SSH, or no clipboard tool), terminals limit how much can be sent at once. oops truncates to roughly 100 KB and warns. OSC 52 is a one-way escape sequence, so oops cannot tell whether the terminal accepted the copy; some terminals ignore it or ask first, and tmux needs `set -g set-clipboard on`.
- Commands longer than 8192 characters are truncated in the recorded command line.
- Output of full-screen apps (vim, less, tmux and so on) is not kept; it is replaced by one line. When the command line holds a single command with a plain name (letters, digits and `. _ + - /`), that line names it, such as `[git: full-screen output omitted]` for `git log` through a pager; otherwise it reads `[full-screen app output omitted]`. Lines printed before and after the full-screen part are kept.
- A command line that starts with a space is recorded in zsh but dropped in bash (bash does not save it to history, which is where oops reads the command).
- bash with [bash-preexec](https://github.com/rcaloras/bash-preexec) (also behind atuin and Ghostty's bash integration): oops registers its hooks with it instead of using its own `DEBUG` trap, whichever of the two comes first in your rc file. A line that bash did not save to history (`HISTCONTROL=ignorespace`, `HISTIGNORE`) is then recorded as `(not saved in history)`, because the text of the line is read from history there. Without bash-preexec, oops records the first command of such a line instead.
- Ghostty adds its shell integration (prompt marks, new tabs in the same directory, titles) only to the outer shell. When it did, the snippet loads it again in the recorded shell, for zsh, fish and bash. Ghostty cannot add it to bash 3.2 (macOS's `/bin/bash`), so there it is not loaded unless you load it yourself below the oops line in `~/.bashrc`: `[ -n "$GHOSTTY_RESOURCES_DIR" ] && source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"`.
- bash: the line after a pipeline sees `PIPESTATUS` with only the last status (`false | true`, then `echo ${PIPESTATUS[*]}` prints `0`, not `1 0`), because oops's `PROMPT_COMMAND` entry runs first. `$?` and `$_` are kept. A prompt that shows pipeline statuses (starship's `pipestatus`) shows less in bash. zsh keeps `pipestatus`.
- macOS: `pbcopy` chooses its text encoding from `LANG` / `LC_*`. If Japanese or other non-ASCII text arrives garbled, check that a UTF-8 locale is set (for example `LANG=en_US.UTF-8`), which can be missing in shells started over SSH.
- Native Windows is not supported yet.

## Development

### Set up your machine

You need Git, Ruby 3.3 or newer, [Bundler](https://bundler.io/) (it ships with Ruby), and both zsh and bash (the end-to-end tests start real shells). macOS has zsh and bash; on Debian or Ubuntu run `sudo apt-get install zsh`. fish is optional: its end-to-end tests are skipped when it is not installed (CI installs it).

```sh
git clone https://github.com/ysb3996-blip/oops.git
cd oops
```

The repository pins Ruby 4.0.9 in `.ruby-version`. With a version manager such as rbenv, asdf or mise, install that version (`rbenv install 4.0.9`, then `rbenv rehash`). Any Ruby 3.3 or newer also works if you delete or ignore the pin. Check with `ruby -v`.

```sh
bin/setup                   # checks Ruby, zsh and bash, installs gems, runs the checks
```

`bin/setup` is the same as `bundle install` followed by `bundle exec rake`. `bundle exec rake` runs the whole test suite (about 30 seconds) and then rubocop (style check); `bundle exec rake test` and `bundle exec rubocop` run them one at a time.

CI runs both on Ubuntu and macOS with Ruby 3.3, 3.4 and 4.0, builds the gem, and runs shellcheck on the bash snippet (`shellcheck -S warning lib/oops/shell/oops.bash bin/setup`, if you have it). Before opening a pull request, run:

```sh
bundle exec rake && gem build oops-cli.gemspec
```

### Try your changes

Run a single test file with `bundle exec ruby -Itest -Ilib test/ansi_test.rb`. To run the command straight from the checkout, without installing anything:

```sh
bundle exec exe/oops --version
bundle exec exe/oops doctor
```

To try it as your shell does, build and install the gem into the Ruby you are using, then add the line from "Set up your shell" to a **new** tab:

```sh
gem build oops-cli.gemspec
gem install ./oops-cli-0.4.1.gem     # the file name follows lib/oops/version.rb
rbenv rehash                         # only with rbenv
```

- A gem is installed per Ruby version. If a new tab uses another Ruby than the one you installed into (for example the repository pins 4.0.9, but your global Ruby is 3.3.5), the shell cannot find oops when it starts (bash prints `bash: oops: command not found`, zsh prints `command not found: oops`). Run `gem install` again under that Ruby, e.g. `RBENV_VERSION=3.3.5 gem install ./oops-cli-0.4.1.gem`.
- Reinstall after every change. The installed gem is a copy, not a link to your checkout.
- To remove it: `gem uninstall oops-cli`.
- Put `eval "$(oops init zsh)"` in your rc file, not just at the prompt: the recorded shell reads the rc file again, and without the line it has no hooks (`oops doctor` shows `hooks: missing`).

Never run `oops record` in the terminal you are working in; the tests drive it through their own pty. Try it in a new terminal tab instead. To delete the logs your experiments leave behind, see "Privacy and security".

The tests cover formatting, secret masking, the log reader, the stream parser and an end-to-end run of the relay with real zsh, bash and fish.

Manual checklist before a release:

- No marker garbage is visible in Ghostty, Terminal.app, iTerm2 and the VS Code integrated terminal.
- vim, less and a full-screen terminal app keep up while you resize the window.
- `exec zsh` in a recorded tab does not start a second recording.
- A VS Code terminal opened with `code .` from a recorded tab is recorded on its own.

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); issues labeled `good first issue` are a good place to start. Every pull request must include the test and rubocop results and a check in a new terminal tab; see [What every pull request must include](CONTRIBUTING.md#what-every-pull-request-must-include).

## Contributors

Thanks to everyone who has helped ([emoji key](https://allcontributors.org/docs/en/emoji-key)). To add someone, comment `@all-contributors please add @<username> for <contributions>` on an issue or pull request.

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/ysb3996-blip"><img src="https://avatars.githubusercontent.com/u/257992595?v=4?s=80" width="80px;" alt="ysb3996-blip"/><br /><sub><b>ysb3996-blip</b></sub></a><br /><a href="https://github.com/ysb3996-blip/oops/commits?author=ysb3996-blip" title="Code">💻</a> <a href="https://github.com/ysb3996-blip/oops/commits?author=ysb3996-blip" title="Documentation">📖</a> <a href="https://github.com/ysb3996-blip/oops/commits?author=ysb3996-blip" title="Tests">⚠️</a> <a href="#maintenance-ysb3996-blip" title="Maintenance">🚧</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/ricky9408"><img src="https://avatars.githubusercontent.com/u/49530170?v=4?s=80" width="80px;" alt="Sanghyuk Lee"/><br /><sub><b>Sanghyuk Lee</b></sub></a><br /><a href="https://github.com/ysb3996-blip/oops/commits?author=ricky9408" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/agenticsymphony-tech"><img src="https://avatars.githubusercontent.com/u/326739730?v=4?s=80" width="80px;" alt="agenticsymphony-tech"/><br /><sub><b>agenticsymphony-tech</b></sub></a><br /><a href="https://github.com/ysb3996-blip/oops/commits?author=agenticsymphony-tech" title="Documentation">📖</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/ShahadatTest"><img src="https://avatars.githubusercontent.com/u/179203101?v=4?s=80" width="80px;" alt="ShahadatTest"/><br /><sub><b>ShahadatTest</b></sub></a><br /><a href="https://github.com/ysb3996-blip/oops/commits?author=ShahadatTest" title="Code">💻</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## License

MIT. See [LICENSE](LICENSE).
