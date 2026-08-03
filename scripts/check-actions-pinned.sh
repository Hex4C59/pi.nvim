#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  set --
  for candidate in .github/workflows/*.yml .github/workflows/*.yaml; do
    if [ -f "$candidate" ]; then
      set -- "$@" "$candidate"
    fi
  done
fi

if [ "$#" -eq 0 ]; then
  exit 0
fi

awk '
  /^[[:space:]]*#/ { next }
  match($0, /uses:[[:space:]]*[^[:space:]#]+/) {
    reference = substr($0, RSTART, RLENGTH)
    sub(/^uses:[[:space:]]*/, "", reference)
    gsub(/^["'\''"]|["'\''"]$/, "", reference)
    if (reference ~ /^\.\//) next
    if (reference !~ /@[0-9a-f]{40}$/) {
      printf "%s:%d: remote action is not pinned to a full commit SHA: %s\n", FILENAME, FNR, $0 > "/dev/stderr"
      failed = 1
    }
  }
  END { exit failed }
' "$@"
