#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_root=$(mktemp -d)
case "$temporary_root" in
  /tmp/* | /var/tmp/*) ;;
  *)
    printf '%s\n' "test_file_target_test: unsafe temporary directory: $temporary_root" >&2
    exit 1
    ;;
esac
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

fake_bin="$temporary_root/bin"
record="$temporary_root/invocation"
output="$temporary_root/output"
expected="$temporary_root/expected"
sentinel="$temporary_root/injection-ran"
mkdir -p "$fake_bin"

make_fake_runner() {
  runner=$1
  script="$fake_bin/$runner"
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '{' \
    '  printf "runner=%s\n" "${0##*/}"' \
    '  for argument do' \
    '    printf "arg=%s\n" "$argument"' \
    '  done' \
    '} > "$PI_TEST_FILE_RECORD"' \
    'exit "${PI_TEST_FILE_EXIT:-0}"' > "$script"
  chmod +x "$script"
}

make_fake_runner nvim
make_fake_runner node

fail() {
  printf '%s\n' "test_file_target_test: $1" >&2
  if [ -s "$output" ]; then
    sed 's/^/  output: /' "$output" >&2
  fi
  if [ -s "$record" ]; then
    sed 's/^/  invocation: /' "$record" >&2
  fi
  exit 1
}

reset_case() {
  : > "$record"
  : > "$output"
  : > "$expected"
  status=0
}

run_make() {
  selection=$1
  runner_status=$2
  if MAKEFLAGS= \
    MFLAGS= \
    MAKEOVERRIDES= \
    PATH="$fake_bin:$PATH" \
    PI_TEST_FILE_RECORD="$record" \
    PI_TEST_FILE_EXIT="$runner_status" \
    make --no-print-directory -s -C "$repo_root" test-file "TEST=$selection" > "$output" 2>&1
  then
    status=0
  else
    status=$?
  fi
}

run_make_without_selection() {
  if (
    unset TEST
    MAKEFLAGS= \
      MFLAGS= \
      MAKEOVERRIDES= \
      PATH="$fake_bin:$PATH" \
      PI_TEST_FILE_RECORD="$record" \
      PI_TEST_FILE_EXIT=0 \
      make --no-print-directory -s -C "$repo_root" test-file > "$output" 2>&1
  )
  then
    status=0
  else
    status=$?
  fi
}

assert_contains() {
  fragment=$1
  if ! grep -F -- "$fragment" "$output" >/dev/null 2>&1; then
    fail "expected output containing: $fragment"
  fi
}

assert_no_runner() {
  [ ! -s "$record" ] || fail "an invalid selection invoked a runner"
}

assert_record() {
  if ! cmp -s "$expected" "$record"; then
    printf '%s\n' "expected invocation:" >&2
    sed 's/^/  /' "$expected" >&2
    fail "runner arguments differed"
  fi
}

expect_invalid() {
  name=$1
  selection=$2
  reason=$3
  reset_case
  run_make "$selection" 0
  [ "$status" -ne 0 ] || fail "$name unexpectedly succeeded"
  assert_contains "$reason"
  assert_contains 'Usage: make test-file TEST=<path>'
  assert_no_runner
}

reset_case
run_make tests/lua/protocol_spec.lua 0
[ "$status" -eq 0 ] || fail "top-level Lua route failed"
printf '%s\n' \
  'runner=nvim' \
  'arg=--headless' \
  'arg=-u' \
  'arg=tests/minimal_init.lua' \
  'arg=-l' \
  'arg=tests/lua/protocol_spec.lua' > "$expected"
assert_record
assert_contains 'nvim: tests/lua/protocol_spec.lua'

reset_case
run_make tests/lua/integration/image_rpc_spec.lua 0
[ "$status" -eq 0 ] || fail "nested Lua route failed"
printf '%s\n' \
  'runner=nvim' \
  'arg=--headless' \
  'arg=-u' \
  'arg=tests/minimal_init.lua' \
  'arg=-l' \
  'arg=tests/lua/integration/image_rpc_spec.lua' > "$expected"
assert_record

reset_case
run_make tests/extensions/todo-list.test.mjs 0
[ "$status" -eq 0 ] || fail "Extension route failed"
printf '%s\n' \
  'runner=node' \
  'arg=--test' \
  'arg=tests/extensions/todo-list.test.mjs' > "$expected"
assert_record
assert_contains 'node: tests/extensions/todo-list.test.mjs'

reset_case
run_make tests/lua/protocol_spec.lua 23
[ "$status" -ne 0 ] || fail "Lua runner failure was swallowed"
printf '%s\n' \
  'runner=nvim' \
  'arg=--headless' \
  'arg=-u' \
  'arg=tests/minimal_init.lua' \
  'arg=-l' \
  'arg=tests/lua/protocol_spec.lua' > "$expected"
assert_record

reset_case
run_make tests/extensions/todo-list.test.mjs 29
[ "$status" -ne 0 ] || fail "Extension runner failure was swallowed"
printf '%s\n' \
  'runner=node' \
  'arg=--test' \
  'arg=tests/extensions/todo-list.test.mjs' > "$expected"
assert_record

reset_case
run_make_without_selection
[ "$status" -ne 0 ] || fail "missing TEST unexpectedly succeeded"
assert_contains 'TEST is required'
assert_contains 'Usage: make test-file TEST=<path>'
assert_no_runner

expect_invalid empty '' 'TEST is required'
expect_invalid absolute /tmp/protocol_spec.lua 'repository-relative test path'
expect_invalid traversal tests/lua/../extensions/todo-list.test.mjs 'repository-relative test path'
expect_invalid nonexistent tests/lua/missing_spec.lua 'does not exist or is not regular'
expect_invalid directory tests/lua 'does not exist or is not regular'
expect_invalid source lua/pi/client.lua 'unsupported test path'
expect_invalid lua-suffix tests/lua/helper.lua 'does not exist or is not regular'
expect_invalid extension-suffix tests/extensions/helper.mjs 'does not exist or is not regular'
expect_invalid smoke tests/smoke/client_smoke.lua 'unsupported test path'
expect_invalid fixture tests/fixtures/fake_pi.js 'unsupported test path'
expect_invalid glob 'tests/lua/*_spec.lua' 'invalid characters'
expect_invalid multiple 'tests/lua/protocol_spec.lua tests/lua/client_spec.lua' 'exactly one test file'

selection='tests/lua/protocol_spec.lua;touch${IFS}'"$sentinel"
expect_invalid semicolon "$selection" 'invalid characters'
selection='tests/lua/protocol_spec.lua&touch${IFS}'"$sentinel"
expect_invalid ampersand "$selection" 'invalid characters'
selection='tests/lua/protocol_spec.lua|touch${IFS}'"$sentinel"
expect_invalid pipe "$selection" 'invalid characters'
selection='tests/lua/protocol_spec.lua`touch '"$sentinel"'`'
expect_invalid backtick "$selection" 'exactly one test file'
selection='tests/lua/protocol_spec.lua$(shell touch '"$sentinel"')'
expect_invalid make-function "$selection" 'exactly one test file'
selection="tests/lua/protocol_spec.lua' touch $sentinel"
expect_invalid single-quote "$selection" 'exactly one test file'
selection="tests/lua/protocol_spec.lua\" touch $sentinel"
expect_invalid double-quote "$selection" 'exactly one test file'

[ ! -e "$sentinel" ] || fail "a metacharacter selection executed commands"

printf '%s\n' "test_file_target_test: ok"
