#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_root=$(mktemp -d)
case "$temporary_root" in
  /tmp/* | /var/tmp/*) ;;
  *)
    printf '%s\n' "exec_plan_policy_test: unsafe temporary directory: $temporary_root" >&2
    exit 1
    ;;
esac
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

checker="$repo_root/scripts/check-exec-plans.mjs"
fixture="$temporary_root/repository"
output="$temporary_root/output"
plan="$fixture/.agent/plans/valid-plan.md"

fail() {
  printf '%s\n' "exec_plan_policy_test: $1" >&2
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

write_valid_plan() {
  cat > "$plan" <<'EOF'
# Deliver A Resumable Change

Status: active

## Purpose

Deliver observable behavior without relying on conversation history.

## Progress

- [ ] 2026-08-04T00:00:00Z - Implement the current milestone.

## Surprises And Discoveries

- Observation: No unexpected behavior is known yet.
  Evidence: Initial repository inspection.

## Decision Log

- Decision: Keep one authoritative plan.
  Rationale: Duplicate plans can drift.
  Date: 2026-08-04

## Context And Orientation

The fixture represents a repository with one active implementation plan.

## Implementation Plan

Implement the owner first, then its adapter and deterministic checks.

## Validation And Acceptance

Run `make test`; success is a zero exit status and the expected behavior.

## Recovery And Idempotence

Repeat deterministic checks and preserve unrelated repository changes.

## Interfaces And Dependencies

The plan depends only on the repository policy checker and Node.js.

## Outcomes And Retrospective

Evaluation remains pending until implementation and verification complete.
EOF
}

node "$checker" --root "$repo_root"

mkdir -p "$fixture/.agent/plans"
cp "$repo_root/.agent/PLANS.md" "$fixture/.agent/PLANS.md"
write_valid_plan
node "$checker" --root "$fixture" > "$output"

sed -i '/^## Recovery And Idempotence$/d' "$plan"
expect_failure 'missing required section: ## Recovery And Idempotence'

write_valid_plan
sed -i 's/^## Purpose$/## TEMPORARY SECTION/; s/^## Progress$/## Purpose/; s/^## TEMPORARY SECTION$/## Progress/' "$plan"
expect_failure 'required sections are out of order'

write_valid_plan
sed -i 's/^Status: active$/Status: complete/' "$plan"
expect_failure 'remove completed plans'

write_valid_plan
mv "$plan" "$fixture/.agent/plans/Invalid_Plan.md"
expect_failure 'plan filename must be lowercase kebab-case'
mv "$fixture/.agent/plans/Invalid_Plan.md" "$plan"

write_valid_plan
sed -i '/^Deliver observable behavior without relying on conversation history\.$/d' "$plan"
expect_failure 'section is empty: ## Purpose'

write_valid_plan
cp "$plan" "$fixture/.agent/plans/second-plan.md"
expect_failure 'at most one active ExecPlan is allowed'

printf '%s\n' "exec_plan_policy_test: ok"
