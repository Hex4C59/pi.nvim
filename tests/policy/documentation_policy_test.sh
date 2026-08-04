#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_root=$(mktemp -d)
case "$temporary_root" in
  /tmp/* | /var/tmp/*) ;;
  *)
    printf '%s\n' "documentation_policy_test: unsafe temporary directory: $temporary_root" >&2
    exit 1
    ;;
esac
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

checker="$repo_root/scripts/check-documentation.mjs"
fixture="$temporary_root/repository"
output="$temporary_root/output"

fail() {
  printf '%s\n' "documentation_policy_test: $1" >&2
  if [ -s "$output" ]; then
    sed 's/^/  /' "$output" >&2
  fi
  exit 1
}

expect_failure() {
  fragment=$1
  if node "$checker" --root "$fixture" > "$output" 2>&1; then
    fail "invalid fixture unexpectedly passed"
  fi
  if ! grep -F -- "$fragment" "$output" >/dev/null 2>&1; then
    fail "failure did not report: $fragment"
  fi
}

node "$checker" --root "$repo_root"

mkdir -p "$fixture/.agent" "$fixture/docs" "$fixture/lua/pi"
printf '%s\n' '# Plans' > "$fixture/.agent/PLANS.md"
printf '%s\n' '# Existing' > "$fixture/docs/existing.md"
printf '%s\n' \
  '# Guide' \
  '' \
  'See [the contract](docs/existing.md), `docs/existing.md`, [a section](#guide),' \
  'the `.agent/PLANS.md` workflow, and [the external documentation](https://example.com/docs).' \
  '' \
  '## Repository Map' \
  '' \
  '```text' \
  'docs/ Documentation' \
  'docs/existing.md Durable contract' \
  'lua/pi/ Lua sources' \
  '```' > "$fixture/AGENTS.md"
printf '%s\n' '# Readme' '[Guide](AGENTS.md)' > "$fixture/README.md"
node "$checker" --root "$fixture" > "$output"

printf '%s\n' '# Readme' '[Missing](docs/missing.md)' > "$fixture/README.md"
expect_failure 'broken local Markdown link: docs/missing.md'

printf '%s\n' '# Readme' '[Guide](AGENTS.md)' > "$fixture/README.md"
printf '%s\n' '# Notes' 'Read `docs/deleted.md` before editing.' > "$fixture/NOTES.md"
expect_failure 'missing local document reference: docs/deleted.md'

printf '%s\n' '# Notes' 'Read `.agent/missing.md` before editing.' > "$fixture/NOTES.md"
expect_failure 'missing local document reference: .agent/missing.md'

rm "$fixture/NOTES.md"
printf '%s\n' \
  '# Guide' \
  '' \
  '## Repository Map' \
  '' \
  '```text' \
  'lua/pi/missing.lua Missing owner' \
  '```' > "$fixture/AGENTS.md"
expect_failure 'repository map path does not exist: lua/pi/missing.lua'

printf '%s\n' "documentation_policy_test: ok"
