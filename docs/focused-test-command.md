# Focused Test Command and Test Quality Plan

> Status: Proposed. The work described in this document is not implemented.
>
> Scope: local test invocation, test-infrastructure regression coverage, test
> failure granularity, and coverage visibility in pi.nvim. This proposal does
> not change runtime behavior, Pi RPC behavior, bundled Extension policy, or the
> requirement for CI to run the full deterministic test gate.

## 1. Summary

Add one explicit Make target for running exactly one test file:

```bash
make test-file TEST=tests/lua/ui/render_spec.lua
```

The same entry point should also run a single bundled Extension test:

```bash
make test-file TEST=tests/extensions/permission-gate.test.mjs
```

The target is intended for the short edit-test loop. It must not infer affected
tests from Git changes, and it must not replace the complete `make test` gate.

The command is the first phase of this plan, not the complete test-quality
outcome. Later phases add an automated contract test for the command, split
overly broad Lua specs along existing ownership boundaries, improve failure
identification, and establish coverage visibility without turning a raw coverage
percentage into the definition of correctness.

## 2. Current Behavior

The current Make targets have deliberately broad meanings:

| Command | Current behavior |
| --- | --- |
| `make test` | Runs every Lua spec, every bundled Extension test, and the repository test policy |
| `make test-lua` | Recursively discovers and runs every `tests/lua/**/*_spec.lua` file |
| `make test-extensions` | Runs every `tests/extensions/*.test.mjs` file |
| `make smoke` | Checks the installed Pi RPC process and bundled Extension loading without calling a model |
| `make format-check` | Checks formatting under `lua/`, `plugin/`, and `tests/` |

Each Lua spec starts its own headless Neovim process. This isolation is useful,
but repeatedly running the full Lua suite slows down the local feedback loop
when a developer is working on one focused behavior.

There is currently no Make entry point for one test file. Developers must
remember and type the underlying Neovim or Node command themselves.

The existing suite has several important strengths:

- Lua unit, command, UI, integration, and regression tests are separated by
  responsibility.
- Bundled Extension policy is tested in Node at the authoritative layer.
- The fake RPC process provides deterministic end-to-end event coverage, while
  smoke tests verify the installed Pi process without calling a model.
- Each Lua spec starts in a separate Neovim process, which prevents state from
  leaking between files.

The known quality gaps are:

- Test-infrastructure behavior is not itself covered by an automated regression
  test.
- Broad files such as `tests/lua/ui/chat_spec.lua` and
  `tests/lua/ui/render_spec.lua` contain several independently owned behaviors,
  so file-level focused execution is still coarse.
- Top-level Lua assertions stop at the first failure in a file and provide no
  test-case-level summary beyond the assertion message.
- The repository has no coverage report or maintained map showing which tests
  protect each critical module and boundary.

## 3. Goals

- Provide one memorable command for a single Lua or Extension test file.
- Preserve the existing meaning of `make test`, `make test-lua`, and
  `make test-extensions`.
- Validate the requested path before starting a test runner.
- Propagate the selected test runner's exit status unchanged.
- Cover the focused command's routing, validation, quoting, and exit behavior
  with a deterministic automated test.
- Keep the command deterministic and free of model calls or authentication.
- Make the focused command convenient without presenting it as a complete
  regression gate.
- Reduce overly broad Lua specs according to module and lifecycle ownership, not
  an arbitrary line-count target.
- Make failures identify a focused behavior without weakening per-file Neovim
  process isolation.
- Establish repeatable coverage visibility for Lua and bundled Extension code.

## 4. Non-goals

This proposal does not:

- Automatically map changed source files to tests.
- Run every test that may be indirectly affected by a source change.
- Add dependency tracking, test result caching, watch mode, or parallel test
  execution.
- Accept directories, shell globs, or multiple test files in one invocation.
- Change GitHub Actions to use focused tests.
- Include smoke or formatting checks in the focused command.
- Require 100% coverage or use a coverage percentage as a substitute for
  boundary, integration, security, or smoke tests.
- Introduce an external Lua test framework before its Neovim 0.10 compatibility,
  offline availability, failure reporting, and cleanup behavior are verified.

Automatic affected-test selection is intentionally excluded. Lua modules are
loaded dynamically, and changes to shared UI, runtime, or RPC code can affect
unit, regression, and integration specs whose files were not modified.

## 5. Command Contract

### 5.1 Interface

The proposed public interface is:

```text
make test-file TEST=<repository-relative-test-path>
```

`TEST` must name exactly one existing regular file using a repository-relative
path. Absolute paths are not accepted.

Supported path forms are:

| Path pattern | Runner |
| --- | --- |
| `tests/lua/**/*_spec.lua` | `nvim --headless -u tests/minimal_init.lua -l <path>` |
| `tests/extensions/*.test.mjs` | `node --test <path>` |

Examples:

```bash
make test-file TEST=tests/lua/client_spec.lua
make test-file TEST=tests/lua/integration/rpc_ui_spec.lua
make test-file TEST=tests/extensions/workspace-guard.test.mjs
```

### 5.2 Validation

The target must fail before invoking Neovim or Node when:

- `TEST` is missing or empty.
- The path is absolute.
- The path contains more than one test selection.
- The path does not exist or is not a regular file.
- The path is outside `tests/lua/` and `tests/extensions/`.
- A Lua path does not end in `_spec.lua`.
- An Extension path does not end in `.test.mjs`.

Failures must print a short reason plus the accepted command form. Invalid input
must return a non-zero exit status.

Shell metacharacters must not be evaluated as commands. The implementation must
quote the validated path when passing it to the selected runner.

### 5.3 Output and exit behavior

Before running the file, the target should print the same runner-oriented prefix
used by the full suite, for example:

```text
nvim: tests/lua/ui/render_spec.lua
```

or:

```text
node: tests/extensions/permission-gate.test.mjs
```

A passing test returns zero. A failing test, missing runner, invalid test path,
or runner startup error returns non-zero without falling back to another test.

## 6. Why Use a Separate Target

An optional `TEST` parameter on `make test-lua` would be shorter, but it would
make the meaning of an existing full-suite command depend on ambient state. For
example, an exported `TEST` variable could accidentally narrow a later
`make test` invocation because `test-lua` is one of its prerequisites.

A dedicated `test-file` target keeps the contracts unambiguous:

- `make test-file TEST=...` always means one explicitly selected test.
- `make test-lua` always means all Lua specs.
- `make test` always means the complete deterministic suite.

This distinction is more important than saving a few characters in the focused
command.

## 7. Intended Workflow

During a focused edit loop:

```bash
make test-file TEST=tests/lua/ui/render_spec.lua
```

After a change affects multiple owners, run the relevant broader suite:

```bash
make test-lua
```

Before considering a change complete, retain the repository's existing gates:

```bash
make test
make format-check
```

Run `make smoke` as well when a change affects installed Pi RPC compatibility or
bundled Extension loading.

## 8. Delivery Plan

### 8.1 Phase 1: focused command and its contract test

1. Add `test-file` to `.PHONY` in `Makefile`.
2. Add one `test-file` recipe that validates `TEST`, selects the runner from the
   path, and executes exactly one file.
3. Add `tests/policy/test_file_target_test.sh` to exercise the public Make
   interface. The test should prepend temporary fake `nvim` and `node`
   executables to `PATH`, record their arguments, and verify runner selection
   without recursively launching the real test suite.
4. Use the existing `test-ci-policy` recursive discovery so the new
   `*_test.sh` contract is included in `make test`. Do not add a second target
   that would run the same policy file twice.
5. Add the focused command to the README development section after the target
   and its contract test exist.
6. Keep the GitHub Actions workflow on `make test` so both supported Neovim
   matrix entries run the complete suite, now including the command contract
   test. CI must never substitute `test-file` for the full gate.

The production runner logic should remain in `Makefile` for this initial
interface. The shell file in this phase is a test, not a second implementation
of the runner. If future requirements add multiple-file selection or
affected-test discovery, that work should receive a separate design rather than
growing opaque Make shell logic.

### 8.2 Phase 2: split broad Lua specs by ownership

After the focused target is protected by its own test, split broad specs where a
file currently covers several independent owners. Line count alone is not a
reason to split a test.

Initial candidates are:

- Split `tests/lua/ui/render_spec.lua` into focused specs below
  `tests/lua/ui/render/` for welcome rendering, Markdown/message rendering, tool
  rendering, and process rendering. Keep a facade-level render spec when it
  protects cross-module composition.
- Split `tests/lua/ui/chat_spec.lua` into focused specs below
  `tests/lua/ui/chat/` for component/window construction, command-menu and input
  interaction, status presentation, transcript interaction, and lifecycle.
  Keep cross-component behavior in a smaller facade-level chat spec.

This split must follow the ownership and test map in
`docs/lua-architecture.md`. A behavior assigned to `pi.ui.transcript`,
`pi.ui.transcript_view`, or a renderer module belongs with that owner rather
than in a generic Chat test.

Each resulting spec must remain independently runnable in a fresh Neovim
process. Shared helpers may be extracted only when they remove meaningful
duplication and do not introduce shared mutable fixtures or hide assertions.

### 8.3 Phase 3: improve failure granularity and reporting

Splitting broad specs provides smaller failure units without adding a dependency
or weakening process isolation. Every spec must:

- Print a stable file-oriented success label.
- Use assertion messages that name the violated behavior and expected outcome.
- Restore any replaced Neovim function or global before exit when the failure
  path can continue executing.
- Avoid grouping unrelated behavior behind one assertion or one large mutable
  fixture.

After the split, evaluate whether a Lua test harness still provides material
value. A harness may be adopted only if it:

- Works on the minimum supported Neovim 0.10 release.
- Is available deterministically without a network fetch during tests.
- Identifies individual cases and preserves non-zero exit status.
- Provides reliable setup and cleanup around global Neovim state.
- Can filter a named case without replacing the file-level `test-file` entry.

Do not add a framework solely to obtain `describe`/`it` syntax. If smaller specs
and descriptive assertions provide adequate diagnostics, retaining the current
dependency-free approach is acceptable and should be recorded as the decision.

### 8.4 Phase 4: establish coverage visibility

Coverage is a diagnostic signal, not an ownership or correctness guarantee.
Introduce it in two steps:

1. Add `tests/README.md` as the durable guide to test categories, focused and
   full commands, and test ownership. Its critical-path coverage map should
   associate transport, runtime, renderer, transcript, permission UI, and
   bundled Extension policy owners with their unit, integration, regression,
   and smoke tests. Start from the current ownership map in
   `docs/lua-architecture.md` rather than duplicating conflicting ownership.
2. Evaluate coverage tooling for Neovim Lua/LuaJIT and Node that works offline,
   supports the minimum versions used by CI, excludes generated or fixture code,
   and emits separate Lua and Extension reports. Pin any new tool before adding
   a repeatable `make coverage` target.

The first coverage report establishes a baseline. Do not fail CI on an arbitrary
percentage initially. A later non-regression gate may be proposed only after the
report is stable across Neovim 0.10 and stable, and critical security and RPC
boundaries remain protected by explicit behavior tests regardless of the
percentage.

Generated coverage output must be ignored and must not be committed. Coverage
collection must use deterministic tests and must not call a model or require
authentication.

## 9. Verification Plan

Phase 1 is complete only after verifying all of the following:

1. Top-level and nested Lua paths route to the fake `nvim` runner with the exact
   expected arguments.
2. A bundled Extension path routes to the fake `node` runner with the exact
   expected arguments.
3. A successful fake runner propagates a zero status.
4. A failing fake runner propagates a non-zero status.
5. Missing, nonexistent, absolute, out-of-scope, and malformed `TEST` values are
   rejected before a runner starts.
6. A path containing shell metacharacters is rejected or handled only as a
   literal path and cannot execute shell syntax.
7. At least one real top-level Lua spec, one real nested Lua spec, and one real
   Extension test pass through `test-file` during implementation verification.
8. `make test` still discovers and runs the complete deterministic suite,
   including the new contract test.
9. `make format-check` still passes.

Items 1 through 6 must be encoded in
`tests/policy/test_file_target_test.sh`; they must not remain manual-only
acceptance checks.

The later quality phases require these additional checks:

10. Every split spec passes independently through `test-file`.
11. The complete suite passes before and after each test move, with no assertion
    silently deleted or weakened merely to complete the split.
12. Failure output identifies the selected file and the behavior that failed.
13. The critical-path coverage map has one or more explicit tests at each
    authoritative boundary.
14. Any adopted coverage tool produces repeatable separate Lua and Extension
    reports on supported local and CI runtimes.

The verification must not call a model or require authentication.

## 10. Risks and Limits

- A selected test can pass while an indirectly affected integration or
  regression test fails. The full suite remains required before completion.
- A file-path interface is explicit but requires the developer to know which
  spec owns the behavior being changed.
- Make recipes execute through a shell, so path validation and quoting are part
  of correctness rather than optional hardening. The automated contract test is
  required to keep this behavior stable.
- The command improves invocation ergonomics only. It does not reduce the
  startup cost within an individual Neovim spec or add test coverage.
- Splitting a spec can accidentally remove sequencing assumptions or shared
  setup. Move assertions without changing their meaning, then add focused setup
  and cleanup explicitly.
- A test harness can add more maintenance cost than reporting value. Treat it as
  a compatibility and ergonomics decision, not a default modernization step.
- Instrumentation can change timing-sensitive UI behavior and make performance
  assertions noisy. Coverage runs must remain separate from normal performance
  regression runs.
- High line coverage can still miss RPC ordering, lifecycle, and fail-closed
  security behavior. These boundaries require explicit tests at their
  authoritative owners.

## 11. Acceptance Criteria

- The focused target accepts exactly one supported repository test file.
- Lua and Extension tests use their existing runners and initialization paths.
- Invalid selections fail clearly and safely.
- The focused target's complete public contract is covered by an automated,
  deterministic policy test.
- Existing full-suite targets retain their current behavior with no parameter-
  dependent narrowing.
- CI continues to run the complete deterministic suite.
- README documentation describes the focused command only after it is shipped.
- Broad Lua specs are split only where ownership boundaries justify it, while
  facade and integration coverage is retained.
- Failures identify a focused behavior, and any test framework decision is
  documented with minimum-version and offline-execution evidence.
- `tests/README.md` documents test categories, commands, and the maintained
  critical-path ownership map.
- Repeatable coverage reporting is available without becoming the sole quality
  gate.
