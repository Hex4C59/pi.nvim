#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_root=$(mktemp -d)
case "$temporary_root" in
  /tmp/* | /var/tmp/*) ;;
  *)
    printf '%s\n' "lua_dependency_policy_test: unsafe temporary directory: $temporary_root" >&2
    exit 1
    ;;
esac
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

checker="$repo_root/scripts/check-lua-architecture.mjs"

fail() {
  printf '%s\n' "lua_dependency_policy_test: $1" >&2
  exit 1
}

expect_failure() {
  name=$1
  root=$2
  fragment=$3
  output="$temporary_root/$name.output"
  if node "$checker" --root "$root" > "$output" 2>&1; then
    fail "$name unexpectedly passed"
  fi
  if ! grep -F -- "$fragment" "$output" >/dev/null 2>&1; then
    sed 's/^/  /' "$output" >&2
    fail "$name did not report $fragment"
  fi
}

node "$checker" --root "$repo_root"

for fixture in forbidden ui-action cycle leak shell-leak client-state comments; do
  mkdir -p "$temporary_root/$fixture/lua/pi/commands" "$temporary_root/$fixture/lua/pi/ui"
done
mkdir -p "$temporary_root/shell-leak/lua/pi/ui/chat"

printf '%s\n' 'return require("pi.ui.chat")' > "$temporary_root/forbidden/lua/pi/commands/demo.lua"
printf '%s\n' 'return {}' > "$temporary_root/forbidden/lua/pi/ui/chat.lua"
expect_failure forbidden "$temporary_root/forbidden" 'command modules must use runtime'

printf '%s\n' 'return require("pi")' > "$temporary_root/ui-action/lua/pi/ui/demo.lua"
expect_failure ui-action "$temporary_root/ui-action" 'UI modules must receive frontend actions'

printf '%s\n' 'return require("pi.b")' > "$temporary_root/cycle/lua/pi/a.lua"
printf '%s\n' 'return require("pi.a")' > "$temporary_root/cycle/lua/pi/b.lua"
expect_failure cycle "$temporary_root/cycle" 'Lua require cycle: pi.a -> pi.b -> pi.a'

printf '%s\n' 'local chat = {}' 'return chat.transcript' > "$temporary_root/leak/lua/pi/commands/demo.lua"
expect_failure leak "$temporary_root/leak" 'Chat facade leak: chat.transcript'

printf '%s\n' 'local chat = {}' 'return chat.input_area' > "$temporary_root/shell-leak/lua/pi/ui/chat/shell.lua"
expect_failure shell-leak "$temporary_root/shell-leak" 'Chat facade leak: chat.input_area'

printf '%s\n' 'local client = {}' 'client.display_queue = {}' 'return client' \
  > "$temporary_root/client-state/lua/pi/runtime.lua"
expect_failure client-state "$temporary_root/client-state" 'Runtime-owned state leaked onto Client: client.display_queue'
printf '%s\n' 'local client = {}' 'client["display_queue"] = {}' 'return client' \
  > "$temporary_root/client-state/lua/pi/runtime.lua"
expect_failure client-state-bracket "$temporary_root/client-state" \
  'Runtime-owned state leaked onto Client: client.display_queue'

printf '%s\n' \
  '-- require("pi.ui.chat")' \
  'local example = "chat.transcript"' \
  'return example' > "$temporary_root/comments/lua/pi/commands/demo.lua"
node "$checker" --root "$temporary_root/comments" >/dev/null

printf '%s\n' "lua_dependency_policy_test: ok"
