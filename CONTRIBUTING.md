# Contributing to oops

English | [日本語](CONTRIBUTING.ja.md)

Thanks for thinking about helping. oops is a small tool and small contributions are welcome: a typo fix, a bug report, a new masking pattern, a shell tweak.

## Ways to help

- **Report a bug** with the [bug report form](https://github.com/ysb3996-blip/oops/issues/new?template=bug_report.md). Run `oops doctor` and paste its output.
- **Suggest an idea** with the [feature request form](https://github.com/ysb3996-blip/oops/issues/new?template=feature_request.md). Describe the situation first, then the change you have in mind.
- **Pick up an issue.** Issues labeled [`good first issue`](https://github.com/ysb3996-blip/oops/labels/good%20first%20issue) are sized for a first contribution. Comment on one before you start so two people do not do the same work.
- **Improve the docs**, including the Japanese translations.

For anything bigger than a small fix, open an issue first so we can agree on the approach before you write code.

## Never paste your session logs

oops stores the raw, unmasked output of every command (see "Privacy and security" in the README). Do not attach a session log to an issue, and read what you paste: masking is a safety net, not a guarantee.

## Set up and send a pull request

The README's "Development" section has the full setup: Ruby 3.3 or newer, `bin/setup`, and how to try your build in a new terminal tab. In short:

```sh
git clone https://github.com/<you>/oops.git && cd oops
bin/setup
git checkout -b fix/short-description
# ...change code...
bundle exec rake && gem build oops-cli.gemspec
```

Before you open the pull request:

- **Write the test first** and watch it fail for the right reason. Bug fixes need a test that fails without the fix.
- Run both commands above (`rake` runs the tests and rubocop). CI runs them on Ubuntu and macOS with Ruby 3.3, 3.4 and 4.0.
- **Verify it yourself and paste the result into the pull request.** This is required, and the pull request template has a section for it. Paste the last lines of `bundle exec rake test` (the `N runs, ... 0 failures` line), the `bundle exec rubocop` summary, and, for any change that affects behavior, what you ran in a **new terminal tab** with your build installed and what it printed (for example `oops doctor` plus the command you tried, or the before and after of the output). Mask anything private first. A pull request without this will be sent back before review.
- Keep each pull request to one change. Explain *why* in the description.
- Commit messages are short and in the form `type(scope): summary`, for example `fix(ansi): keep words apart when a UI places them with cursor column jumps`. Common types: `fix`, `feat`, `docs`, `test`, `style`, `refactor`.
- If you change the README or CHANGELOG, update the Japanese file (`README.ja.md`, `CHANGELOG.ja.md`) too. If you cannot write Japanese, say so in the pull request and a maintainer will help.

## Ground rules for the code

- **No runtime gem dependencies.** oops installs with plain `gem install`; keep it that way. Development tools go in the Gemfile only.
- Ruby 3.3 is the minimum. macOS and Linux, zsh and bash are supported; do not break one for another. The shell snippets must also work on macOS's bash 3.2.
- Match the style around your change (naming, comment density, idiom). `bundle exec rubocop` must be clean.
- Never run `oops record` in the terminal you are working in. The tests drive it through their own pty.
- Masking must stay linear in the input size. A new pattern needs a test, and patterns that scan across text need bounded spans (see the guard tests in `test/secrets_test.rb`).

## Conduct

Be kind and assume good faith. Disagree about code, not about people. Maintainers may close issues and pull requests that are abusive or off topic.

## License

By contributing you agree that your contribution is licensed under the MIT License, the same as the project.
