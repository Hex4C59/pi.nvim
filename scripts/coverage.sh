#!/bin/sh
set -eu

fail() {
  printf '%s\n' "coverage: $1" >&2
  exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
coverage_root="$repo_root/coverage"

[ -n "$repo_root" ] || fail "repository root is empty"
[ "$repo_root" != "/" ] || fail "repository root cannot be the filesystem root"
[ -e "$repo_root/.git" ] || fail "repository root is unresolved"
[ "$coverage_root" = "$repo_root/coverage" ] || fail "coverage root is not the expected repository child"
[ "$coverage_root" != "$repo_root" ] || fail "coverage root cannot be the repository root"
[ "$coverage_root" != "/" ] || fail "coverage root cannot be the filesystem root"
if [ -n "${HOME-}" ] && [ "$coverage_root" = "${HOME-}" ]; then
  fail "coverage root cannot be the home directory"
fi

cd "$repo_root"

validate_tools() {
  command -v nvim >/dev/null 2>&1 || fail "nvim is required"
  command -v node >/dev/null 2>&1 || fail "Node >=20.1 is required"
  node scripts/coverage/validate-tools.mjs
}

clear_coverage() {
  if [ -L "$coverage_root" ]; then
    fail "refusing to clear a symlinked coverage root"
  fi
  if [ -e "$coverage_root" ] && [ ! -d "$coverage_root" ]; then
    fail "coverage root exists but is not a directory"
  fi
  if [ -d "$coverage_root" ]; then
    find "$coverage_root" -mindepth 1 -depth -delete
    rmdir "$coverage_root"
  fi
}

collect() {
  validate_tools
  clear_coverage

  lua_dir="$coverage_root/lua"
  lua_raw="$lua_dir/raw"
  extension_dir="$coverage_root/extensions"
  mkdir -p "$lua_raw" "$extension_dir"

  lua_specs="$lua_dir/specs.manifest"
  lua_sources="$lua_dir/sources.manifest"
  lua_stats="$lua_dir/stats.manifest"
  lua_merged="$lua_dir/merged.stats"
  lua_report="$lua_dir/summary.txt"

  find tests/lua -type f -name '*_spec.lua' -print | LC_ALL=C sort >"$lua_specs"
  find lua/pi -type f -name '*.lua' -print | LC_ALL=C sort >"$lua_sources"
  printf '%s\n' plugin/pi.lua >>"$lua_sources"
  : >"$lua_stats"

  index=0
  while IFS= read -r test_file; do
    index=$((index + 1))
    stats_file=$(printf '%s/process-%04d.stats' "$lua_raw" "$index")
    [ ! -e "$stats_file" ] || fail "duplicate Lua stats artifact: $stats_file"
    printf '%s\n' "coverage nvim: $test_file"
    PI_NVIM_COVERAGE_REPO="$repo_root" \
      PI_NVIM_COVERAGE_STATS="$stats_file" \
      nvim --headless -u scripts/coverage/lua_init.lua -l "$test_file"
    printf '%s\n' "$stats_file" >>"$lua_stats"
  done <"$lua_specs"
  [ "$index" -gt 0 ] || fail "no Lua specs were discovered"

  PI_NVIM_COVERAGE_REPO="$repo_root" \
    PI_NVIM_COVERAGE_RAW_ROOT="$lua_raw" \
    PI_NVIM_COVERAGE_STATS_MANIFEST="$lua_stats" \
    PI_NVIM_COVERAGE_SOURCE_MANIFEST="$lua_sources" \
    PI_NVIM_COVERAGE_MERGED="$lua_merged" \
    nvim --headless -u NONE -l scripts/coverage/lua_merge.lua

  PI_NVIM_COVERAGE_REPO="$repo_root" \
    PI_NVIM_COVERAGE_MERGED="$lua_merged" \
    PI_NVIM_COVERAGE_REPORT="$lua_report" \
    nvim --headless -u NONE -l scripts/coverage/lua_report.lua

  find "$lua_raw" -mindepth 1 -depth -delete
  rmdir "$lua_raw"
  find "$lua_specs" "$lua_sources" "$lua_stats" -maxdepth 0 -type f -delete

  extension_tests="$extension_dir/tests.manifest"
  extension_report="$extension_dir/summary.txt"
  find tests/extensions -type f -name '*.test.mjs' -print | LC_ALL=C sort >"$extension_tests"

  set --
  while IFS= read -r test_file; do
    set -- "$@" "$test_file"
  done <"$extension_tests"
  [ "$#" -gt 0 ] || fail "no Extension tests were discovered"

  PI_NVIM_COVERAGE_REPO="$repo_root" \
    PI_NVIM_EXTENSION_COVERAGE_REPORT="$extension_report" \
    node --test --experimental-test-coverage \
      --test-reporter="$repo_root/scripts/coverage/extensions-reporter.mjs" \
      "$@"
  [ -f "$extension_report" ] || fail "Node did not emit an Extension coverage report"
  find "$extension_tests" -maxdepth 0 -type f -delete

  printf '\n%s\n' "Lua report: coverage/lua/summary.txt"
  cat "$lua_report"
  printf '\n%s\n' "Extension report: coverage/extensions/summary.txt"
  cat "$extension_report"
}

case "${1-}" in
  validate)
    validate_tools
    ;;
  clean)
    clear_coverage
    ;;
  collect)
    collect
    ;;
  *)
    fail "usage: scripts/coverage.sh {validate|collect|clean}"
    ;;
esac
