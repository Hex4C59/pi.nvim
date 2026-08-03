# Task 18: Add the Tests Guide and Critical-Path Ownership Map

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 17
>
> Blocks: Tasks 19 through 21

## 1. Goal

Add a durable `tests/README.md` that explains how to run tests, where new tests
belong, which layer owns each invariant, and which focused/full checks are
required for common changes.

Unlike the numbered task documents, `tests/README.md` remains after this plan is
complete. It must describe shipped behavior and current ownership, not future
intent.

## 2. Target File

Create:

```text
tests/README.md
```

Do not copy the entire root `AGENTS.md` or parent proposal. Link to them for
security/architecture detail and keep the tests guide operational.

## 3. Required Document Structure

### 3.1 Purpose and guarantees

State that deterministic tests:

- do not call a model;
- do not require authentication;
- use fake RPC for event sequencing;
- test Extension policy at the authoritative Extension layer;
- isolate each Lua spec in a fresh headless Neovim process; and
- keep installed-process smoke separate.

Do not describe bundled guards as a sandbox.

### 3.2 Command reference

Document the shipped commands and exact scope:

| Command | Scope | Intended use |
| --- | --- | --- |
| `make test-file TEST=...` | Exactly one supported Lua or Extension test file | Local focused loop |
| `make test-lua` | Every recursively discovered Lua spec | Lua subsystem gate |
| `make test-extensions` | Every bundled Extension policy test | Extension gate |
| `make test` | Complete deterministic suite including policy/runner contract | Completion and CI gate |
| `make format-check` | StyLua check | Formatting gate |
| `make smoke` | Installed Pi and Extension loading, no model | Compatibility gate |
| `make ci-policy-check` | GitHub Actions pin policy | CI policy gate |
| `make coverage` | Separate diagnostic coverage run, only after Task 20 ships | Coverage visibility |

Do not document `make coverage` before it exists. Until Task 20, include a
clearly marked coverage status rather than a command example.

### 3.3 Directory map

Explain each current directory:

```text
tests/lua/             focused Lua behavior
tests/lua/commands/    command adapters and dispatch
tests/lua/ui/          Neovim UI components
tests/lua/integration/ fake-RPC and cross-owner workflows
tests/lua/regression/  memory/performance regressions
tests/extensions/      authoritative Extension policy
tests/fixtures/        deterministic fake processes/data
tests/smoke/           installed Pi checks without model calls
tests/policy/          repository/test-infrastructure policy
```

List nested renderer/chat directories only after Tasks 05 through 15 have
actually created them.

### 3.4 Critical-path ownership map

Create a table with at least:

| Owner | Primary focused tests | Cross-owner regression/integration | Smoke requirement |
| --- | --- | --- | --- |
| JSONL parser | protocol spec | client/fake RPC | client smoke when protocol compatibility changes |
| RPC client | client spec | RPC UI integration | client smoke |
| Runtime event projection | runtime/dispatch focused tests | RPC UI integration | capability-dependent |
| Commands/catalogue | command specs | RPC UI integration | installed command capability when no-model |
| Renderer text/welcome/messages/tools/process | focused renderer specs | Chat facade/RPC UI | none normally |
| Transcript model | transcript spec | output budget/RPC UI | none normally |
| TranscriptView | view spec | performance/output budget | none normally |
| InputArea/CommandMenu/Chat | component/facade specs | layout/RPC UI | none normally |
| Dialog/permission presentation | UI specs | RPC UI | Extension UI smoke where supported |
| Permission policy | Extension tests | client permission UI separately | Extension loading smoke |
| Workspace/session-root guard | Extension tests | Lua preflight only as defense in depth | Extension loading smoke |
| Image data/backend/preview | image specs | image RPC integration | capability-dependent no-model smoke |

Use actual file names after decomposition. One test may appear in multiple
cross-owner rows, but each state/policy invariant must have one authoritative
owner.

### 3.5 Change-to-test matrix

Provide concise guidance:

- parser/client edit -> focused protocol/client, fake RPC integration, full gate;
- runtime event edit -> focused runtime/dispatch plus RPC UI;
- renderer edit -> owner renderer spec plus Chat facade;
- transcript budget edit -> model spec plus output-budget regression;
- UI component edit -> component spec plus layout/facade as relevant;
- Extension policy edit -> authoritative Node test plus UI adapter test if UI
  changes;
- Extension loading/API edit -> `make smoke`;
- GitHub Actions edit -> policy checks; and
- broad refactor -> focused tests during work, full test/format/smoke before
  completion according to scope.

### 3.6 Writing a new test

Document conventions:

- use `*_spec.lua` recursively for Lua;
- use `*.test.mjs` at the supported Extension location;
- name by owner/behavior;
- keep one process per Lua file;
- use structured fixtures, not parsed rendered prose for semantics;
- give every assertion a behavior-oriented message;
- use bounded waits;
- restore patched globals and clean resources;
- avoid model/auth/network dependencies;
- use focused target during development and full target before completion; and
- do not weaken authoritative Extension tests in favor of Lua UI tests.

### 3.7 Harness decision

Summarize the durable outcome of Task 17:

- current approach;
- why it was selected;
- how to run/filter at supported granularity; and
- where cleanup helpers, if any, live.

Do not include candidate research that will become stale.

### 3.8 Coverage interpretation

After Task 20, document:

- how to generate reports;
- output location;
- which files are excluded and why;
- baseline date/tool versions;
- no arbitrary 100% expectation;
- why security/RPC/lifecycle tests remain explicit; and
- why performance tests run outside instrumentation if required.

Before Task 20, state only that objective coverage reporting is planned and not
currently shipped.

## 4. Cross-Document Consistency

Check `tests/README.md` against:

- root `AGENTS.md` testing/ownership tables;
- `Makefile` target behavior;
- `.github/workflows/ci.yml`;
- README development commands;
- installed supported Pi version; and
- current test directory contents.

Do not create a second source of truth with conflicting command semantics. The
tests guide is the operational index; root architecture instructions remain
authoritative for ownership rules.

## 5. Verification

Verify every documented command that exists:

```bash
make test-file TEST=tests/lua/protocol_spec.lua
make test-file TEST=tests/extensions/todo-list.test.mjs
make test
make format-check
make ci-policy-check
make smoke
```

Confirm every linked test path exists and every directory description matches
actual discovery behavior. Smoke must not call a model.

## 6. Risks

- A hand-maintained map can become stale. Update it in the same changeset when a
  test owner/path changes.
- Do not list planned files as shipped.
- Avoid duplicating long architecture/security explanations that belong in
  `AGENTS.md`.
- A coverage table is not proof of exercised branches; distinguish test
  ownership from measured instrumentation.

## 7. Completion Checklist

- [ ] `tests/README.md` exists and describes only shipped behavior.
- [ ] Every public test command has accurate scope.
- [ ] Directory and critical-path ownership maps match the repository.
- [ ] Change-to-test guidance preserves authoritative owners.
- [ ] Test-writing, cleanup, async, and no-model conventions are documented.
- [ ] Task 17's harness decision is recorded durably.
- [ ] Coverage is marked shipped or unimplemented truthfully.
- [ ] Every documented command/path was verified.
- [ ] Full deterministic, formatting, policy, and no-model smoke checks pass.

