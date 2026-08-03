# Task 20: Implement the Coverage Command and Record the Baseline

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 19 and an accepted Task 19 tooling decision
>
> Blocks: Task 21

## 1. Goal

Implement a repeatable, separate `make coverage` workflow using only tooling
accepted by Task 19. Produce distinct Lua and Extension reports, record the first
baseline, and document interpretation without adding an arbitrary CI percentage
gate.

If Task 19 rejects tooling for either language, do not invent a replacement in
this task. Update the durable tests guide with the verified limitation and defer
implementation for that language.

## 2. Scope and Files

Expected changes, adjusted to the selected tooling:

- `Makefile`: public coverage target and narrow cleanup/helper targets.
- tool-specific pinned configuration or dependency metadata.
- `.gitignore`: generated coverage output only.
- `tests/README.md`: shipped commands, scope, exclusions, and baseline summary.
- minimal helper script only if multi-process setup/merge cannot remain readable
  in Make.

Do not modify production Lua/Extension code solely to improve reported numbers.
Do not change normal test targets to run under instrumentation.

## 3. Public Command Contract

The intended public entry is:

```bash
make coverage
```

It must:

1. validate required pinned tools before starting;
2. clear only the repository's validated generated coverage directory;
3. collect fresh Lua coverage across the selected deterministic specs;
4. merge per-Neovim-process data;
5. collect Extension coverage across all authoritative Node tests;
6. generate separate human-readable summaries;
7. preserve any test failure as a non-zero result;
8. avoid a model, authentication, installed Pi mutation, or network fetch; and
9. print report locations.

Coverage collection itself may be slower than `make test`; it is a diagnostic
command, not the local focused loop.

## 4. Lua Collection

Implement the exact Task 19 design. Required properties:

- each Lua spec still starts in its own headless Neovim process unless Task 19
  proved an equally isolated alternative;
- each process writes a unique result artifact;
- reports merge only artifacts from the current invocation;
- original `lua/pi/**/*.lua` and `plugin/pi.lua` paths are used;
- test/fixture/third-party files are excluded;
- a failing spec fails the coverage command; and
- missing coverage for an unloaded module is shown, not silently excluded.

If the timing-sensitive performance spec is excluded from instrumentation, run
it uninstrumented in the coverage workflow and document that its source paths may
not contribute data.

## 5. Extension Collection

Implement the accepted Node design with:

- every `tests/extensions/*.test.mjs` file;
- `extensions/lib/*.mjs` included;
- `.ts` entry-point coverage only where source mapping was proven reliable;
- tests, Node internals, global Pi, and generated cache excluded;
- Node test status preserved; and
- no replacement of `make smoke`.

Report direct policy-helper and entry-point coverage separately when one report
would obscure the TypeScript loading limitation.

## 6. Generated Output and Cleanup

Use the exact output root approved by Task 19, preferably:

```text
coverage/
```

Before deleting stale output:

- resolve repository root;
- verify the target is the expected child directory;
- reject empty, absolute-root, home, workspace-root, or unresolved targets; and
- delete only generated coverage artifacts.

Add the generated root to `.gitignore`. Do not ignore general JSON, HTML, or Lua
files broadly.

## 7. Baseline Report

Generate the first baseline and record in `tests/README.md`:

- date;
- Neovim/LuaJIT and Node versions;
- coverage tool versions;
- included/excluded source roots;
- summary percentages separately for Lua and Extensions;
- uncovered critical modules/regions;
- known instrumentation blind spots;
- performance-spec treatment; and
- exact reproduction command.

Do not commit generated HTML/raw data. Keep only a concise summary and ownership
interpretation.

## 8. Interpretation and Follow-Up

Review uncovered code by risk, not only percentage:

1. fail-closed Extension policy;
2. RPC framing/correlation/queue limits;
3. transcript/view memory and lifecycle;
4. dialog cancellation and permission UI;
5. cleanup/timer/subprocess error paths;
6. command capability limitations; and
7. lower-risk display formatting.

Create focused behavior-test follow-ups for material gaps. Do not add assertions
that merely execute lines without checking outcomes.

No CI threshold is introduced in this task. A later non-regression proposal must
demonstrate stable reports across both Neovim matrix versions and must use
owner-aware floors rather than one repository-wide number.

## 9. Documentation Updates

### `tests/README.md`

Replace the planned coverage status with shipped command, prerequisites, report
paths, exclusions, baseline, and interpretation.

### `docs/focused-test-command.md`

Mark only the implemented coverage phase complete and record any rejected or
partial tooling result truthfully.

### Numbered tasks

Update Tasks 19 and 20 with actual tooling/version/verification records. Do not
mark Task 21 complete.

## 10. Verification

Run normal gates first:

```bash
make test
make format-check
```

Run coverage from a clean generated-output state:

```bash
make coverage
```

Run it a second time and confirm stale artifacts do not change totals:

```bash
make coverage
```

Then verify normal behavior remains uninstrumented:

```bash
make test
make smoke
make ci-policy-check
```

Smoke must not call a model.

Test failure propagation by temporarily forcing a selected coverage-run test to
fail, confirming non-zero status, and immediately restoring the temporary edit.
Do not commit the failure.

## 11. Risks

- Cleanup is destructive within the generated directory. Resolve and validate
  its exact path before deletion.
- Stale per-process files can inflate coverage.
- Instrumentation can alter performance/timing behavior.
- Coverage can expose source paths/content in reports; keep reports local and
  exclude secrets/external code.
- Tool installation can add significant dependency metadata. Keep changes
  pinned and scoped.
- A high percentage can create false confidence. Maintain explicit behavior and
  ownership tests.

## 12. Completion Checklist

- [ ] Only Task 19-approved tooling was used.
- [ ] `make coverage` is deterministic and separate from normal tests.
- [ ] Lua multi-process data merges without stale artifacts.
- [ ] Extension reports preserve source ownership and test status.
- [ ] Generated output is narrowly ignored and never committed.
- [ ] Baseline versions, scope, exclusions, and gaps are recorded.
- [ ] No arbitrary CI threshold was added.
- [ ] Forced failure propagates non-zero status.
- [ ] Repeated coverage runs are stable.
- [ ] Normal test, format, smoke, and policy gates pass without a model call.

