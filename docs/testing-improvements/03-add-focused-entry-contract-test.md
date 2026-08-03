# Task 03: Add an Automated Contract Test for the Focused Entry

> Status: Completed on 2026-08-04.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 and 02
>
> Blocks: Task 04

## 1. Goal

Add a deterministic shell regression test for the public
`make test-file TEST=...` contract and include that regression in the complete
`make test` gate.

The contract test must verify routing, exact runner arguments, path validation,
diagnostics, quoting, and exit-code propagation without launching a real model,
the installed Pi process, or the full test suite recursively.

## 2. Files and Ownership

### New file

`tests/policy/test_file_target_test.sh`

This file owns regression coverage for the Make-level focused-test interface.
It does not test Lua plugin behavior or Extension policy.

### Makefile discovery contract

`Makefile` already discovers `tests/policy/**/*_test.sh` through
`test-ci-policy`, and `test` already depends on that target. Verify this remains
true; no Makefile edit is needed merely to enumerate the new contract test.

Do not fold this test into `tests/policy/actions_policy_test.sh`. GitHub Actions
pinning policy and focused-runner behavior are independent concerns and need
independent failure labels.

## 3. Test Isolation Design

The contract test must create a temporary directory with `mktemp -d` and remove
it through an idempotent `trap` on normal exit, assertion failure, or signal.

Inside the temporary directory, create fake `nvim` and `node` executables that:

1. record which executable was selected;
2. record each argument without losing argument boundaries;
3. return a caller-controlled exit status; and
4. never execute Neovim, Node, Pi, or a model.

Prepend the fake-binary directory to a task-specific `PATH` only for the nested
`make test-file` process. Do not alter the parent shell's PATH and do not write
fake executables into the repository.

Use separate record lines or NUL-safe storage so the test can distinguish one
path argument from two accidentally split arguments. The current supported path
character set excludes whitespace, but exact argument boundaries remain part of
the contract.

## 4. Assertion Helpers

Keep the shell test dependency-free. Define small local helpers for:

- failing with a stable test name and diagnostic;
- expecting a command to succeed;
- expecting a command to fail;
- asserting that output contains a reason fragment;
- asserting the selected fake runner;
- asserting the exact ordered argument list;
- asserting no runner was invoked; and
- resetting the invocation record between cases.

Every failure must print the case name. Do not rely only on `set -e`, because an
unlabelled non-zero status makes CI diagnosis unnecessarily difficult.

Use `set -eu`. Do not require non-POSIX shell features unless the Makefile and CI
explicitly adopt that shell in the same task, which is not planned.

## 5. Required Test Matrix

### 5.1 Lua routing

Verify a top-level Lua test path:

```text
tests/lua/protocol_spec.lua
```

Expected fake runner and arguments:

```text
nvim
--headless
-u
tests/minimal_init.lua
-l
tests/lua/protocol_spec.lua
```

Verify a nested Lua path such as:

```text
tests/lua/integration/image_rpc_spec.lua
```

This case proves discovery is not limited to one directory depth.

### 5.2 Extension routing

Verify:

```text
tests/extensions/todo-list.test.mjs
```

Expected fake runner and arguments:

```text
node
--test
tests/extensions/todo-list.test.mjs
```

Confirm `nvim` was not invoked for this case.

### 5.3 Status propagation

Run one valid Lua selection with the fake runner configured to return a unique
non-zero status such as 23. Assert the nested Make invocation returns that
status rather than zero, one, or a fallback runner's status.

Repeat for the Extension route if the Make implementation has separate command
branches whose status propagation could diverge.

### 5.4 Missing and malformed selections

Each case must fail before any fake runner is invoked:

| Case | Example |
| --- | --- |
| Missing value | no `TEST` assignment |
| Empty value | `TEST=` |
| Absolute path | `/tmp/protocol_spec.lua` |
| Parent traversal | `tests/lua/../extensions/todo-list.test.mjs` |
| Missing file | `tests/lua/missing_spec.lua` |
| Directory | `tests/lua` |
| Source path | `lua/pi/client.lua` |
| Wrong Lua suffix | `tests/lua/helper.lua` |
| Wrong Extension suffix | `tests/extensions/helper.mjs` |
| Smoke test | `tests/smoke/client_smoke.lua` |
| Fixture | `tests/fixtures/fake_pi.js` |
| Glob | `tests/lua/*_spec.lua` |
| Multiple selections | two paths in one value |

Assert both the non-zero status and an appropriate stable error fragment.

### 5.5 Metacharacter handling

Use values containing at least:

- semicolon;
- ampersand;
- pipe;
- backtick;
- dollar sign and parentheses;
- single quote; and
- double quote.

Create a sentinel path in the temporary directory and express the malicious
cases so an accidental evaluation would create or modify the sentinel. Assert
the sentinel remains unchanged and neither fake runner is invoked.

This test demonstrates safe handling of shell syntax. It does not claim that a
Make command-line assignment is a security boundary against arbitrary GNU Make
language expressions; document any remaining Make-language limitation rather
than describing the test runner as a sandbox.

### 5.6 Output prefixes

For successful routes assert stdout contains exactly one relevant prefix:

```text
nvim: tests/lua/protocol_spec.lua
```

or:

```text
node: tests/extensions/todo-list.test.mjs
```

Invalid selections must not print a misleading runner prefix.

## 6. Makefile Integration

### 6.1 Verify policy discovery

File: `Makefile`, `test` prerequisites.

Confirm `test-ci-policy` recursively discovers `*_test.sh`, and that `test`
depends on it without removing or conditionally skipping:

- `test-lua`;
- `test-extensions`; or
- `test-ci-policy`.

Do not add a separate target for this one policy file; it would duplicate the
recursive discovery. Do not add the contract test to `test-file` itself; that
would create recursion.

## 7. Verification Commands

Run the contract directly:

```bash
sh tests/policy/test_file_target_test.sh
```

Run all policy contracts through Make:

```bash
make test-ci-policy
```

Run the actual focused entry once for each runner:

```bash
make test-file TEST=tests/lua/protocol_spec.lua
make test-file TEST=tests/extensions/todo-list.test.mjs
```

Run the complete gate:

```bash
make test
make format-check
```

Successful behavior:

- the policy test prints one stable success label;
- fake runners receive exact argument vectors;
- no invalid selection invokes a runner;
- injected metacharacters do not execute;
- non-zero fake-runner status is preserved; and
- the full suite still runs every deterministic category.

## 8. Risks

- A fake runner that stores arguments using an unquoted `$*` can hide the exact
  argument-splitting bug it is meant to detect.
- Temporary PATH changes can leak into later tests if not scoped to the nested
  Make process.
- Recursive Make inherits command-line variables. Explicitly override only the
  variables needed for each case.
- Testing a real test file through a fake runner proves routing, not test
  behavior. The real focused smoke commands remain required once during
  implementation.
- Do not use `mktemp` output as a recursive deletion target without first
  confirming it is non-empty and task-specific.

## 9. Completion Checklist

- [x] The contract test is a new independent policy file.
- [x] Temporary resources are always cleaned.
- [x] Fake runners never invoke real Neovim, Node, Pi, or a model.
- [x] Top-level and nested Lua routing are covered.
- [x] Extension routing is covered.
- [x] Exact argument boundaries are covered.
- [x] Missing, malformed, out-of-scope, and nonexistent paths are covered.
- [x] Metacharacter cases cannot create the sentinel.
- [x] Runner failures propagate non-zero status.
- [x] Existing policy discovery includes the test in `make test` exactly once
      without recursion.
- [x] Real focused Lua and Extension smoke commands pass.
- [x] `make test` and `make format-check` pass or match the Task 01 baseline.

## 10. Handoff to Task 04

Record the final public command, stable diagnostics, Make target names, and test
file path. Task 04 documents only behavior that actually exists and has passed
this contract.

## 11. Implementation Record

`tests/policy/test_file_target_test.sh` uses task-scoped temporary fake `nvim`
and `node` executables. It records one argument per line, checks the exact vector,
forces independent non-zero failures, verifies stable diagnostics, and exercises
semicolon, ampersand, pipe, backtick, Make-function, and quote inputs against a
sentinel. The policy is discovered exactly once by `test-ci-policy`.
