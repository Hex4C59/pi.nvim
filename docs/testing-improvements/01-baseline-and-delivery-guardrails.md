# Task 01: Record the Test Baseline and Delivery Guardrails

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Dependencies: none
>
> Blocks: Tasks 02 through 21

## 1. Goal

Record a trustworthy baseline before changing the test runner or moving any
test. The baseline must distinguish repository failures that already exist in
the current working tree from regressions introduced by later tasks.

This task changes no runtime code, test behavior, or CI configuration. Its only
durable change is filling in the implementation record at the end of this file
when the task is executed.

## Task Sequence

This file is also the index for the numbered plan. Execute tasks in numeric
order except where the dependency column explicitly permits parallel work.

| Task | Phase | Depends on | Primary deliverable |
| --- | --- | --- | --- |
| 01 | Baseline | none | Tool versions, test inventory, results, and timing baseline |
| 02 | Focused entry | 01 | Validated `make test-file TEST=...` command |
| 03 | Focused entry | 01-02 | Automated Make/runner contract policy test |
| 04 | Focused entry | 01-03 | README publication and complete Phase 1 verification |
| 05 | Renderer tests | 01-04 | Text and welcome focused specs |
| 06 | Renderer tests | 01-05 | Message, Markdown, and media-boundary specs |
| 07 | Renderer tests | 01-06 | Tool renderer focused spec |
| 08 | Renderer tests | 01-07 | Process spec and reduced renderer facade spec |
| 09 | Transcript tests | 01-08 | Complete direct Transcript model coverage |
| 10 | Transcript tests | 01-09 | Direct TranscriptView projection/lifecycle coverage |
| 11 | Component tests | 01-10 | Direct InputArea coverage |
| 12 | Component tests | 01-10 | Direct CommandMenu coverage |
| 13 | Chat tests | 01-12 | Chat shell, wiring, ownership, and layout coverage |
| 14 | Chat tests | 01-13 | Structured transcript interaction coverage |
| 15 | Chat tests | 01-14 | Lifecycle spec and reduced Chat facade spec |
| 16 | Diagnostics | 01-15 | Failure-message, async, and cleanup audit |
| 17 | Harness decision | 01-16 | Evidence-based adopt/retain/defer decision |
| 18 | Durable docs | 01-17 | `tests/README.md` and critical-path ownership map |
| 19 | Coverage decision | 01-18 | Lua/Node coverage tooling compatibility decision |
| 20 | Coverage delivery | 01-19 | Repeatable coverage command and baseline, if accepted |
| 21 | Closeout | applicable 01-20 | Final gates, ownership audit, and plan-document cleanup |

Tasks 11 and 12 may be developed in parallel after Task 10, but Task 13 requires
both. Task 20 is conditional on Task 19 accepting viable tooling; an evidence-
based rejection proceeds to Task 21 as a documented outcome rather than a fake
or partial implementation.

Use these status values consistently in every numbered file:

- `Proposed`: no implementation work has been accepted.
- `In progress`: the task has started but not passed every completion check.
- `Completed`: every required deliverable and verification result exists.
- `Blocked`: a concrete external or compatibility condition prevents progress
  and the implementation record contains evidence.

## 2. Why This Task Exists

The working tree may already contain unrelated or in-progress Lua refactors.
Later tasks will move assertions between files, add a Make target, and add test
infrastructure checks. Without a recorded baseline, a later failure can be
misclassified as either:

- a regression caused by the testing work;
- a pre-existing failure in the current working tree;
- a local tool-version mismatch; or
- a compatibility failure against the installed Pi process.

The repository also has several different verification layers. `make test`,
`make format-check`, `make smoke`, and `make ci-policy-check` do not mean the
same thing and must be recorded separately.

## 3. Ownership Boundary

- Pi core remains authoritative for RPC and Extension protocol behavior.
- Bundled Extensions remain authoritative for permission and workspace policy.
- This task observes test and tool behavior only.
- No model request, authentication flow, package installation, or global Pi
  replacement is authorized by this task.

## 4. Preconditions

1. Work from the repository root.
2. Read the current root `AGENTS.md` before running commands.
3. Inspect `git status --short` and preserve every pre-existing change.
4. Do not stash, reset, format, or otherwise rewrite the working tree.
5. Confirm that `nvim`, `node`, `make`, `stylua`, and `pi` resolve to the tools
   intended for this repository.

## 5. Baseline Inventory

Record the following without editing generated output into source files:

### 5.1 Tool versions

Run:

```bash
nvim --version
node --version
make --version
stylua --version
pi --version
```

Record at minimum:

- Neovim version and LuaJIT version.
- Node major version.
- GNU Make version.
- StyLua version.
- Installed Pi version and resolved executable path.

Confirm the Pi path with:

```bash
readlink -f "$(command -v pi)"
```

### 5.2 Test inventory

Run:

```bash
find tests/lua -type f -name '*_spec.lua' -print | LC_ALL=C sort
find tests/extensions -maxdepth 1 -type f -name '*.test.mjs' -print | LC_ALL=C sort
find tests/smoke tests/policy -type f -print | LC_ALL=C sort
```

Record:

- The number of Lua specs.
- The number of Extension test files.
- The smoke files.
- The policy test files.
- Any test file that does not match the discovery patterns in `Makefile`.

### 5.3 Current Make contracts

Read `Makefile` and confirm:

- `make test` depends on every deterministic test category.
- `make test-lua` recursively discovers nested `*_spec.lua` files.
- `make test-extensions` runs all top-level `*.test.mjs` files.
- `make test-ci-policy` recursively discovers every `*_test.sh` policy file.
- `make smoke` is separate from the deterministic suite.
- `make format-check` is separate from the deterministic suite.
- All public test targets are phony and therefore do not use timestamp-based
  incremental skipping.

### 5.4 Baseline results and duration

Run the deterministic and formatting gates first:

```bash
time make test
time make format-check
make ci-policy-check
```

Run the installed-process check separately:

```bash
make smoke
```

`make smoke` must not call a model. If it would require credentials, paid API
usage, or an unplanned Pi installation change, stop and record the reason rather
than broadening the task.

For each command record:

- exit status;
- elapsed time;
- the first failing file and assertion, if any;
- whether the failure reproduces when that file is run directly; and
- whether the failure is known to predate this task.

## 6. Baseline Interpretation

Use these rules when interpreting results:

- A fully passing baseline is preferred but not required to start planning.
- A known failing baseline must be written down before later changes begin.
- A later task must not hide a known failure by removing a target or assertion.
- A timing value is diagnostic only. Do not establish a hard performance target
  from one run on one machine.
- Smoke failure does not justify modifying Pi core or the installed package as
  part of this testing-only plan.

## 7. Required Deliverable

When this task is executed, update only the implementation record below with:

- date and commit or working-tree identifier;
- tool versions;
- test counts;
- command results and elapsed times;
- known baseline failures;
- the exact installed Pi version used for smoke; and
- a short statement confirming that no model was called.

Do not mark later task documents as implemented from this task.

## 8. Verification

This task is complete when another maintainer can answer all of these questions
from the implementation record:

1. Which toolchain was used?
2. How many test files did each full target discover?
3. Which gates passed or failed before any test-infrastructure edit?
4. How long did the full deterministic suite take approximately?
5. Which failures, if any, were already present?
6. Which installed Pi executable was used for smoke?
7. Was any model request made?

## 9. Risks

- Running tests in a dirty working tree can produce a baseline that differs from
  `HEAD`. Record that fact; do not discard the changes.
- Local Neovim stable may be newer than the minimum CI version. Passing locally
  does not replace the Neovim 0.10 matrix check.
- Timing-sensitive UI tests may vary between runs. Record large variance rather
  than weakening assertions.
- Smoke depends on the installed Pi process and is not a substitute for the fake
  RPC integration suite.

## 10. Completion Checklist

- [ ] Working-tree state was inspected and preserved.
- [ ] Tool versions were recorded.
- [ ] Test discovery counts were recorded.
- [ ] `make test` result and duration were recorded.
- [ ] `make format-check` result and duration were recorded.
- [ ] `make ci-policy-check` result was recorded.
- [ ] `make smoke` result and installed Pi version were recorded, or a precise
      non-model blocker was documented.
- [ ] No source, test, Makefile, CI, or installed Pi artifact was changed.
- [ ] No model was called.

## 11. Implementation Record

> Not executed yet. Fill this section when Task 01 is performed.
