#!/usr/bin/env bash
# Records docs/demo.gif with vhs (brew install vhs). Builds a throwaway home
# directory under /tmp/oops-demo with a failing test and a .env, points it at
# this checkout's exe/oops and the current Ruby, then runs the tape. macOS
# only: the tape shows the clipboard with pbpaste.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
home=/tmp/oops-demo/home
ruby_bin=$(dirname "$(ruby -e 'puts RbConfig.ruby')")
if ! ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3")'; then
  echo "record.sh: oops needs Ruby 3.3 or newer; \`ruby\` here is $(ruby -v)" >&2
  exit 1
fi

rm -rf /tmp/oops-demo
mkdir -p "$home/app"

cat > "$home/.bashrc" <<RC
export PATH="$repo/exe:$ruby_bin:/opt/homebrew/bin:/usr/bin:/bin"
eval "\$(oops init bash)"
PS1='\[\e[32m\]\$\[\e[0m\] '
RC
printf '. ~/.bashrc\n' > "$home/.bash_profile"

cat > "$home/app/test_user.rb" <<'RB'
require "minitest/autorun"

class User
  def initialize(first, last) = (@first, @last = first, last)
  def full_name = @first
end

class UserTest < Minitest::Test
  def test_full_name
    assert_equal "Taro Yamada", User.new("Taro", "Yamada").full_name
  end
end
RB
printf 'DATABASE_URL=postgres://localhost/app_dev\nOPENAI_API_KEY=sk-live-4f9Qm2Xr8tL0pZ7vK1nB3cD6eF5gH9jA\n' > "$home/app/.env"

cd "$repo" && vhs docs/demo/demo.tape
