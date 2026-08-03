# Task 19: Evaluate Coverage Tooling for Neovim Lua and Extensions

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 18
>
> Blocks: Tasks 20 and 21

## 1. Goal

Select or reject tooling for repeatable source coverage reports across:

- Lua code executed inside headless Neovim/LuaJIT; and
- bundled Extension policy code executed by Node tests.

This is a tooling spike and decision record. It must not add a coverage command,
CI gate, package dependency, or committed report. Task 20 implements only the
tooling proven here.

## 2. Why a Separate Spike Is Required

Coverage requirements cross several constraints:

- each Lua spec starts a separate Neovim process;
- results must merge across those processes;
- the minimum supported Neovim is 0.10.4;
- Neovim embeds LuaJIT rather than using a project-managed standalone Lua;
- Node tests load `.mjs` policy helpers and TypeScript Extension entry points may
  be loaded through Pi/jiti in smoke;
- tests must run offline after dependencies are installed/pinned;
- instrumentation can distort timing-sensitive regression tests; and
- no default test may call a model.

A tool that produces a report on the current developer machine but cannot
reproduce in CI or on Neovim 0.10 is not acceptable.

## 3. Required Coverage Scope

### 3.1 Lua include scope

Evaluate collection for:

```text
lua/pi/**/*.lua
plugin/pi.lua
```

Report `plugin/pi.lua` separately if headless minimal initialization does not
source it naturally.

### 3.2 Lua exclusions

Exclude:

- `tests/**`;
- generated files, if any;
- temporary/cache paths;
- installed Pi package code; and
- optional third-party plugin code.

Do not exclude hard-to-cover pi.nvim modules merely to improve a percentage.

### 3.3 Extension include scope

Evaluate collection for:

```text
extensions/*.ts
extensions/lib/*.mjs
```

Distinguish direct policy-helper coverage from entry-point loading exercised
only by smoke. If the Node coverage tool cannot map jiti-loaded TypeScript entry
points accurately, report that limitation explicitly.

### 3.4 Extension exclusions

Exclude:

- `tests/**`;
- installed/global Pi code;
- Node internals;
- generated/transpiled cache; and
- temporary directories.

## 4. Candidate Evaluation Criteria

For each Lua and Node candidate record:

- primary upstream documentation/source;
- pinned version and license;
- supported runtime versions;
- LuaJIT/Neovim compatibility;
- line and branch coverage support;
- multi-process result format and merge behavior;
- source-map behavior for TypeScript, if applicable;
- include/exclude filtering;
- deterministic offline invocation;
- installation mechanism;
- CI integration requirements;
- local setup burden;
- performance overhead; and
- known blind spots.

Prefer existing runtime/toolchain capabilities over adding a framework when they
meet the contract. Verify current behavior from primary documentation at task
execution time; do not rely on remembered version semantics.

## 5. Lua Prototype

The prototype must:

1. Instrument one pure focused spec.
2. Instrument one buffer/window UI spec.
3. Run two specs in separate Neovim processes.
4. Merge their data without one process overwriting another.
5. Attribute lines to original `lua/pi/` source paths.
6. Produce a bounded human-readable summary.
7. Return non-zero on test failure independent of report generation.
8. Run on Neovim 0.10.4 and stable.
9. Avoid changing normal `make test` behavior.
10. Remove all prototype output after evaluation.

Verify instrumentation does not require system Python. If a report tool requires
Python, it must use a documented project environment; this repository currently
does not declare one, so adding that dependency requires separate justification.

## 6. Node Prototype

The prototype must:

1. Run one existing Extension policy test file.
2. Report coverage for `extensions/lib/*.mjs`.
3. Evaluate whether `.ts` Extension entry files can be mapped without changing
   production loading.
4. Exclude test and Node internal files.
5. Preserve Node test exit status.
6. Work on the minimum Node major enforced by CI and the current local version.
7. Require no model, Pi authentication, or network access during execution.

Do not replace the installed-extension smoke with source coverage. Loading the
real Pi API remains a separate compatibility check.

## 7. Performance and Timing Isolation

Measure overhead for representative focused and full Lua runs. Determine whether
`tests/lua/regression/performance_spec.lua` can run under instrumentation without
false failures.

Preferred policy:

- normal `make test` remains uninstrumented;
- `make coverage` is a separate diagnostic target;
- timing-sensitive performance assertions run uninstrumented if coverage hooks
  materially alter scheduling/call behavior;
- excluded performance execution is still run normally before a coverage task
  is considered successful; and
- the exclusion is documented, not hidden.

## 8. Output and Repository Hygiene

Evaluate an output layout such as:

```text
coverage/lua/
coverage/extensions/
coverage/summary/
```

Requirements:

- paths are repository-local and explicitly ignored;
- one task run cannot merge stale data from a previous run;
- cleanup targets validate the narrow coverage directory;
- raw per-process files are bounded/removed after merge;
- no source payload, prompt content, secret, or global installed code is copied
  into reports; and
- reports are not committed.

## 9. Decision Record

Fill this task's implementation record with:

- candidates and versions;
- compatibility matrix;
- prototype commands;
- merged-report evidence;
- overhead measurements;
- selected Lua tool or explicit rejection;
- selected Node tool or explicit rejection;
- selected include/exclude policy;
- performance-test policy;
- dependency/pinning plan; and
- blockers that Task 20 must respect.

If no acceptable Lua or Node tool exists, mark the corresponding coverage phase
blocked with evidence. Do not implement a misleading partial percentage.

## 10. Verification

After removing temporary prototype changes/output:

```bash
git status --short
make test
make format-check
```

Confirm only the intended decision-record edit remains from this task and all
user pre-existing changes are preserved.

## 11. Risks

- Debug hooks can change LuaJIT optimization and event timing.
- Multi-process files can race or overwrite when names are not unique.
- Node TypeScript source maps can report generated/cache paths instead of source.
- Coverage tools are supply-chain dependencies and require pinning.
- A combined percentage can hide zero coverage in a critical small module.
  Reports must remain separated by owner/language.
- Coverage is not proof of assertion quality or fail-closed security behavior.

## 12. Completion Checklist

- [ ] Lua and Node candidates were checked against primary sources.
- [ ] Minimum and stable runtimes were tested.
- [ ] Separate-process Lua data merged correctly or a blocker was recorded.
- [ ] Extension helper and TypeScript mapping behavior was established.
- [ ] Include/exclude and performance policies were selected.
- [ ] Dependency, pinning, offline, and license costs were recorded.
- [ ] Prototype output and temporary code were removed.
- [ ] Normal tests remain unchanged and pass.

## 13. Implementation Record

> Not executed yet. Fill this section when Task 19 is performed.

