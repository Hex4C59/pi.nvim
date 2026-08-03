#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

valid="$temporary_root/valid.yml"
invalid_tag="$temporary_root/tag.yml"
invalid_main="$temporary_root/main.yaml"
invalid_short="$temporary_root/short.yml"
local_action="$temporary_root/local.yaml"

printf '%s\n' 'steps:' '  - uses: owner/repo@0123456789abcdef0123456789abcdef01234567' > "$valid"
printf '%s\n' 'steps:' '  - uses: owner/repo@v7' > "$invalid_tag"
printf '%s\n' 'steps:' '  - uses: owner/repo@main' > "$invalid_main"
printf '%s\n' 'steps:' '  - uses: owner/repo@0123456' > "$invalid_short"
printf '%s\n' 'steps:' '  - uses: ./local/action' > "$local_action"

sh "$repo_root/scripts/check-actions-pinned.sh" "$valid" "$local_action"
for invalid in "$invalid_tag" "$invalid_main" "$invalid_short"; do
  if sh "$repo_root/scripts/check-actions-pinned.sh" "$invalid" >/dev/null 2>&1; then
    printf '%s\n' "Expected policy failure for $invalid" >&2
    exit 1
  fi
done

mkdir -p "$temporary_root/.github/workflows"
cp "$invalid_main" "$temporary_root/.github/workflows/fixture.yaml"
if (cd "$temporary_root" && sh "$repo_root/scripts/check-actions-pinned.sh" >/dev/null 2>&1); then
  printf '%s\n' "Expected default .yaml workflow scan to fail" >&2
  exit 1
fi

printf '%s\n' "actions_policy_test: ok"
