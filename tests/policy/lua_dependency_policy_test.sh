#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

if rg -n 'require.*pi\.ui\.' "$repo_root/lua/pi/commands"; then
  printf '%s\n' "Command modules must not require pi.ui.*" >&2
  exit 1
fi

printf '%s\n' "lua_dependency_policy_test: ok"
