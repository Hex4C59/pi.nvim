# Task 17: Make an Evidence-Based Lua Test Harness Decision

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 16
>
> Blocks: Tasks 18 through 21

## 1. Goal

Decide whether pi.nvim should retain dependency-free top-level Lua specs or adopt
a test harness for named cases, filtering, setup/cleanup, and summary reporting.

This is a decision task, not an authorization to migrate the suite. The outcome
must be based on measured remaining pain after the large specs have been split
and cleanup/reporting has been audited.

## 2. Decision Question

Answer:

> After file-level decomposition and cleanup improvements, does a harness provide
> enough additional diagnostic and maintenance value to justify its dependency,
> compatibility, and migration costs?

The valid outcomes are:

1. Retain the current dependency-free approach.
2. Adopt a small repository-owned harness.
3. Adopt a pinned external harness.
4. Defer because a required compatibility fact cannot yet be established.

Do not assume that `describe`/`it` syntax is inherently better.

## 3. Required Evidence

### 3.1 Current-suite evidence

Measure and record:

- number of Lua spec files after Tasks 05 through 15;
- largest remaining spec files;
- typical focused-test duration;
- number of specs requiring protected cleanup;
- whether file-plus-assertion output now identifies failures adequately;
- whether developers need to filter multiple cases inside one remaining file;
- observed flaky or cross-scenario state problems; and
- maintenance duplication that a harness would actually remove.

### 3.2 Minimum-version compatibility

Evaluate candidates against:

- Neovim 0.10.4;
- the current stable Neovim used by CI;
- LuaJIT versions bundled by those Neovim releases;
- Node-free execution for Lua-only tests;
- headless `-l` invocation; and
- no network access during the test run.

Use candidate primary documentation and a local no-model prototype. Do not rely
on current-stable-only Neovim APIs when the repository supports 0.10.4.

### 3.3 Dependency and supply-chain cost

For each external candidate record:

- package source and pinning mechanism;
- whether it requires a plugin manager;
- whether CI must download it;
- transitive dependencies;
- release/support status;
- license compatibility;
- startup-time cost; and
- how offline contributors run tests.

An unpinned network fetch in `tests/minimal_init.lua` is not acceptable.

### 3.4 Functional capability

Evaluate whether the candidate provides:

- named cases in failure output;
- one named case/filter execution;
- before/after cleanup that runs on failure;
- asynchronous Neovim support;
- traceback preservation;
- non-zero process status;
- deterministic ordering;
- compatibility with one process per spec or an explicit replacement model;
- no hidden global mutation; and
- machine-readable output only if there is an actual CI consumer.

## 4. Repository-Owned Harness Criteria

A custom harness is acceptable only if it remains small and removes repeated
real complexity. It must not grow into a second testing framework.

At minimum it would need:

- a named `case` wrapper;
- protected traceback;
- always-run cleanup;
- stable summary and exit status;
- optional exact case filter;
- no dependency on Neovim APIs newer than 0.10; and
- direct tests for the harness itself.

Estimate implementation and maintenance cost before selecting this option.
Avoid a custom assertion DSL; Lua `assert` remains adequate for values.

## 5. Prototype Procedure

For each serious candidate:

1. Create a temporary prototype outside committed test paths.
2. Express one pure renderer case.
3. Express one buffer/window cleanup case.
4. Express one bounded asynchronous wait case.
5. Force a failure and inspect file/case/traceback output.
6. Filter and run exactly one named case.
7. Run on Neovim 0.10.4 and stable.
8. Measure startup time relative to the current focused command.
9. Remove the temporary prototype after recording results.

Do not migrate production specs during this task.

## 6. Decision Record

At execution time, fill the implementation record with:

- date and tested Neovim versions;
- candidates considered;
- compatibility/result table;
- measured remaining problem;
- selected outcome;
- reasons;
- rejected alternatives and tradeoffs;
- follow-up work, if any; and
- review date if deferred.

Copy a concise durable conclusion into `tests/README.md` in Task 18. Do not make
contributors rediscover the decision from an obsolete task plan.

## 7. If a Harness Is Selected

Do not implement it inside this decision task. Add a separately reviewed plan
before migration that specifies:

- dependency acquisition/pinning;
- minimal-init changes;
- harness self-tests;
- one pilot spec;
- rollback path;
- incremental migration order;
- coexistence with old specs;
- CI updates; and
- final removal of compatibility paths.

The focused file command must continue to work throughout migration.

## 8. If No Harness Is Selected

Record why current behavior is sufficient, including:

- small owner-aligned spec files;
- stable Make file prefix;
- descriptive assertion messages;
- protected cleanup in stateful specs;
- one-process-per-file isolation; and
- absence of a proven case-filtering need.

This is a valid engineering outcome, not unfinished modernization.

## 9. Verification

Regardless of the decision, run the existing suite unchanged:

```bash
make test
make format-check
```

If candidate prototypes change any tracked file, restore only those prototype
changes and verify the user's unrelated working-tree edits remain intact.

## 10. Risks

- Framework evaluation can expand into a suite rewrite. Keep this task
  read-mostly and decision-only.
- Current stable Neovim success can hide minimum-version failure.
- A framework can encourage combining all tests in one process, weakening the
  current isolation guarantee.
- Case aggregation after failure may run later cases against corrupted global
  Neovim state.
- Developer familiarity is useful but not sufficient evidence for a dependency.

## 11. Completion Checklist

- [ ] Remaining reporting/filtering pain was measured after decomposition.
- [ ] Minimum and stable Neovim were evaluated.
- [ ] Offline and dependency costs were recorded.
- [ ] Cleanup, async, traceback, filtering, and status behavior were prototyped.
- [ ] One of the four valid outcomes was selected with reasons.
- [ ] No suite migration was smuggled into the decision task.
- [ ] `make test` and `make format-check` still pass.

## 12. Implementation Record

> Not executed yet. Fill this section when Task 17 is performed.

