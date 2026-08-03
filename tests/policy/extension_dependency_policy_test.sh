#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

fail() {
  printf '%s\n' "extension_dependency_policy_test: $1" >&2
  exit 1
}

assert_entry_policy() {
  entry=$1
  expected=$2
  actual=$(sed -n 's/.*from "\.\/lib\/security\/\([^"]*\.mjs\)";.*/\1/p' "$repo_root/extensions/$entry")
  [ "$actual" = "$expected" ] || fail "$entry must import only $expected, found: ${actual:-none}"
}

assert_entry_policy permission-gate.ts permission.mjs
assert_entry_policy workspace-guard.ts workspace.mjs
assert_entry_policy session-root-guard.ts session-root.mjs

[ ! -e "$repo_root/extensions/lib/security-policy.mjs" ] || fail "security-policy.mjs monolith returned"
[ ! -e "$repo_root/extensions/lib/security/index.mjs" ] || fail "aggregate security index is forbidden"

for policy in permission workspace session-root; do
  file="$repo_root/extensions/lib/security/$policy.mjs"
  [ -f "$file" ] || fail "$policy policy is missing"
  if grep -E 'from "\./(permission|workspace|session-root)\.mjs"' "$file" >/dev/null 2>&1; then
    fail "$policy policy imports a sibling policy"
  fi
done

printf '%s\n' "extension_dependency_policy_test: ok"
