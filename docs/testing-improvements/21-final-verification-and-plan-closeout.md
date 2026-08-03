# Task 21: Run Final Verification and Close Out the Test Improvement Plan

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 20, except explicitly documented rejected
> optional tooling outcomes

## 1. Goal

Verify the complete testing workflow across focused, full, formatting, policy,
coverage, and installed-process layers; compare it with Task 01; confirm owner
boundaries; and remove or convert one-time planning documents after durable
behavior is captured.

This task is not an opportunity for unrelated test refactors. Any material
failure returns to the owning earlier task.

## 2. Preconditions

Before final verification:

- Tasks 01 through 16 have truthful completion records.
- Task 17 has a durable harness decision.
- `tests/README.md` describes actual shipped structure and commands.
- Task 19 has an accepted/rejected coverage decision with evidence.
- Task 20 is complete for every accepted coverage tool, or the verified tooling
  limitation is documented.
- no task is marked complete solely because a file exists.
- all unrelated user working-tree changes remain preserved.

## 3. Structural Audit

### 3.1 Test discovery

List and compare actual files with Make patterns:

```bash
find tests/lua -type f -name '*_spec.lua' -print | LC_ALL=C sort
find tests/extensions -maxdepth 1 -type f -name '*.test.mjs' -print | LC_ALL=C sort
find tests/policy tests/smoke -type f -print | LC_ALL=C sort
```

Confirm:

- every intended spec is discovered;
- no helper accidentally matches a test suffix;
- no old broad spec duplicates all moved behavior;
- every focused owner has a discoverable test; and
- no planned-but-unimplemented path is documented as shipped.

### 3.2 Assertion accounting

Review renderer and Chat decomposition records. Confirm every pre-split
assertion is:

- moved to the authoritative focused owner;
- retained in a smaller facade/integration test; or
- intentionally superseded by a documented stronger assertion.

Search for accidental copied duplicates and stale fixtures.

### 3.3 Resource ownership

Confirm tests reflect exactly one owner for:

- Pi session/model/queue state;
- Extension permission mode and approvals;
- RPC process/parser/pending requests;
- Transcript items and byte accounting;
- TranscriptView buffers/projections/ranges;
- InputArea/CommandMenu/Chat windows and interaction;
- image backend/preview resources; and
- timers/jobs/temp files.

Lua UI tests must not claim authoritative Extension policy behavior.

## 4. Focused Entry Verification

Run:

```bash
make test-ci-policy
make test-file TEST=tests/lua/protocol_spec.lua
make test-file TEST=tests/lua/ui/render/process_spec.lua
make test-file TEST=tests/lua/ui/chat/lifecycle_spec.lua
make test-file TEST=tests/lua/integration/rpc_ui_spec.lua
make test-file TEST=tests/extensions/permission-gate.test.mjs
```

Confirm:

- exactly one selected file runs each time;
- top-level and deeply nested Lua paths work;
- Extension routing works;
- prefixes identify the file;
- failures propagate; and
- `TEST` never narrows a later full-suite command.

## 5. Complete Deterministic and Formatting Gates

Run:

```bash
make test
make format-check
make ci-policy-check
```

Run `make test` once with an irrelevant exported `TEST` value and confirm the
full discovery count remains unchanged. Clear the variable afterward.

Compare with Task 01:

- number of files;
- total elapsed time;
- first-failure diagnostic quality;
- focused-test elapsed time; and
- known baseline failures.

More files may make the full suite slower because each Lua file starts Neovim.
Record the tradeoff rather than merging owners back into broad specs. Optimize
only if measured startup overhead is materially harmful.

## 6. Coverage Verification

If Task 20 shipped coverage:

```bash
make coverage
```

Confirm:

- fresh results;
- separate Lua/Extension summaries;
- current source paths;
- documented exclusions;
- no generated report tracked by Git;
- no performance false failure; and
- no arbitrary percentage used as the sole gate.

If coverage tooling was rejected, confirm `tests/README.md` says so precisely and
does not advertise `make coverage`.

## 7. Installed-Process Smoke

Record:

```bash
pi --version
readlink -f "$(command -v pi)"
make smoke
```

Confirm the installed Pi matches the repository's supported baseline and the
smoke invokes no model. This task does not authorize patching/installing Pi; an
incompatibility returns to the owner with evidence.

## 8. CI Matrix Confirmation

Confirm `.github/workflows/ci.yml` still:

- runs `make test` on Neovim 0.10.4 and stable;
- runs formatting separately;
- checks pinned Actions;
- does not use changed-files selection as the full gate; and
- needs no credentials/model access.

If coverage is not in CI, documentation must describe it as a local diagnostic.
Do not add CI coverage thresholds during closeout.

## 9. Documentation Truth Audit

Read together:

- `README.md` development section;
- `tests/README.md`;
- root `AGENTS.md` testing and ownership sections;
- `docs/focused-test-command.md`;
- `docs/lua-architecture.md`; and
- these numbered task documents.

Resolve contradictions in favor of implemented code and authoritative ownership.
README must describe shipped commands only.

## 10. Plan Document Closeout

Repository documentation rules require completed one-time task documents to be
removed after durable behavior is captured.

After every applicable task is complete and verified:

1. Ensure command usage, directory ownership, test-writing rules, harness
   decision, and coverage interpretation live in `tests/README.md`, root
   `AGENTS.md`, README, Makefile, and tests as appropriate.
2. Convert any still-useful architectural rationale into a current architecture
   section rather than leaving it in a completed task checklist.
3. Remove `docs/testing-improvements/` and
   `docs/focused-test-command.md` in the same closeout changeset.
4. Preserve `docs/lua-architecture.md` as the durable source for implemented
   frontend ownership and dependency boundaries.
5. Run documentation link/path searches after removal.

Until that point, keep all task files explicitly marked Proposed/In Progress/
Completed truthfully.

## 11. Final Report

Record and hand off:

- implemented command surface;
- focused/full timing comparison;
- final test counts by category;
- renderer/Transcript/View/Input/Menu/Chat ownership structure;
- harness decision;
- coverage decision and baseline if shipped;
- deterministic/format/policy/smoke results;
- installed Pi version/path;
- residual risks and missing tests;
- confirmation that no model was called; and
- list of one-time documents removed or intentionally retained.

## 12. Risks

- Final cleanup can delete useful rationale before durable docs contain it.
  Verify content migration first.
- More focused files increase Neovim startup overhead in full runs.
- A local stable-only pass does not cover Neovim 0.10.4.
- Smoke failure can tempt an unrelated Pi installation change; keep ownership
  and authorization boundaries.
- Coverage metrics can distract from explicit security/lifecycle assertions.
- A dirty worktree may contain user changes across the same docs/tests. Merge
  carefully and never discard them.

## 13. Completion Checklist

- [ ] Every intended test file is discovered exactly once.
- [ ] Focused entry contract and representative real selections pass.
- [ ] Full deterministic, format, and policy gates pass.
- [ ] Coverage passes or its verified rejection is documented truthfully.
- [ ] Installed Pi smoke passes without a model call.
- [ ] Both CI Neovim versions retain the full gate.
- [ ] Assertion moves and authoritative owners were audited.
- [ ] Durable README/AGENTS/tests documentation is complete.
- [ ] Task 01 comparison and residual risks are recorded.
- [ ] One-time planning documents are removed only after durable migration.
