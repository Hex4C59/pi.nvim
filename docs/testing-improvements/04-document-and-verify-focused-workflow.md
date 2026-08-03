# Task 04: Document and Verify the Focused Workflow

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 03
>
> Blocks: Tasks 05 through 21

## 1. Goal

Publish the implemented focused-test workflow in the durable developer
documentation and verify that it improves local feedback without weakening the
complete deterministic or installed-process gates.

This task closes Phase 1 of the parent plan. It does not begin test-file moves,
coverage tooling, or test-framework adoption.

## 2. Preconditions

Before editing documentation, confirm:

- `make test-file` exists.
- Lua and Extension routing pass real focused smoke checks.
- `tests/policy/test_file_target_test.sh` covers the public contract.
- existing policy discovery includes the contract test in `make test` exactly
  once.
- no known failure differs from the Task 01 baseline.

If any item is false, return to Task 02 or 03. Do not document proposed syntax as
shipped behavior.

## 3. Documentation Edit

### 3.1 README development section

File: `README.md`, `## Development` section, immediately after the existing
`make test` example and before the JSONL parser explanation.

Add a concise focused-test subsection containing:

- the purpose: fast local feedback for one known test file;
- one Lua example;
- one Extension example;
- a statement that the command accepts exactly one repository-relative test
  file;
- a statement that it does not discover affected tests; and
- a statement that `make test` remains required before completion.

Use the actually implemented command and diagnostics. Do not describe coverage,
multi-file selection, watch mode, or automatic Git mapping.

Recommended examples:

```bash
make test-file TEST=tests/lua/ui/render_spec.lua
make test-file TEST=tests/extensions/permission-gate.test.mjs
```

### 3.2 Parent proposal status

File: `docs/focused-test-command.md`, status block and Phase 1 sections.

Do not mark the entire proposal complete. Record only Phase 1 as implemented,
including:

- implementation date;
- public target name;
- contract test path;
- full-suite integration target;
- verification results; and
- any deliberate difference from the proposed validation wording.

The remaining spec decomposition, reporting, ownership-map, and coverage work
must remain explicitly proposed.

### 3.3 Task document status

Files:

- `docs/testing-improvements/01-baseline-and-delivery-guardrails.md`
- `docs/testing-improvements/02-implement-focused-test-entry.md`
- `docs/testing-improvements/03-add-focused-entry-contract-test.md`
- this file

Update status and implementation-record sections only after each task's
completion criteria have actually passed. Do not bulk-mark tasks complete based
on code presence alone.

## 4. Full Verification

### 4.1 Focused real tests

Run:

```bash
make test-file TEST=tests/lua/protocol_spec.lua
make test-file TEST=tests/lua/integration/image_rpc_spec.lua
make test-file TEST=tests/extensions/todo-list.test.mjs
```

Confirm each invocation runs exactly one file and prints one correct runner
prefix.

### 4.2 Contract and deterministic suite

Run:

```bash
make test-ci-policy
make test
make format-check
make ci-policy-check
```

Confirm `make test` output still includes:

- every recursively discovered Lua spec;
- all Extension test files;
- the Actions policy test; and
- the focused-entry contract test.

### 4.3 Installed-process smoke

Run:

```bash
make smoke
```

Smoke remains separate because it verifies the installed Pi process and bundled
Extension loading. It must not call a model.

### 4.4 CI configuration audit

Read `.github/workflows/ci.yml` and confirm both supported Neovim matrix entries
still invoke `make test`. The workflow must not use `test-file`, a hard-coded
spec list, or a changed-files filter as its primary gate.

## 5. Expected Results

The phase is successful when:

- one known test can be launched with a short stable command;
- invalid focused selections fail clearly;
- the focused command is protected by deterministic regression coverage;
- README distinguishes focused feedback from full verification;
- CI continues to run the complete deterministic suite; and
- smoke remains a separate no-model installed-process check.

## 6. Risks

- README can accidentally turn a convenience command into the apparent release
  gate. Keep the full-suite requirement adjacent to the examples.
- Do not publish an option that is accepted only by a local uncommitted version
  of `Makefile`.
- A passing focused test can hide indirect regressions. The documentation must
  state this directly.
- Do not mark the parent plan complete; most of its quality work occurs in later
  tasks.
- Smoke can fail because the installed Pi version differs from the supported
  baseline. Record the mismatch rather than changing Pi in this task.

## 7. Completion Checklist

- [ ] README documents the shipped focused command.
- [ ] README includes Lua and Extension examples.
- [ ] README explicitly retains `make test` as the complete gate.
- [ ] Parent plan records Phase 1 only as implemented.
- [ ] Tasks 01 through 03 contain truthful implementation records.
- [ ] Real top-level, nested, and Extension focused checks pass.
- [ ] The automated contract test passes.
- [ ] `make test`, `make format-check`, and `make ci-policy-check` pass or match
      the recorded baseline.
- [ ] `make smoke` passes against the installed supported Pi version without a
      model call, or a precise compatibility blocker is recorded.
- [ ] CI continues to run the full deterministic suite on both Neovim entries.

## 8. Handoff to Task 05

Record the measured full-suite and focused-test durations from this phase. Task
05 begins moving renderer assertions into smaller owner-aligned specs; it must
use the shipped `test-file` target during every move and the full suite after
each independently reviewable batch.
