# Focused Test Command and Test Quality Plan

> Status: In progress. Phases 1 through 4 were implemented and verified on
> 2026-08-04; only the final plan audit and closeout remain.
> Phase 2 is underway: Chat ownership specs and direct Transcript model,
> projection, retention, history, TranscriptView, renderer text, welcome,
> message, Markdown, tool, process, and facade specs are complete; remaining
> UI-owner work is tracked by `docs/modular-architecture-plan.md`. Direct
> InputArea buffer, frame, footer, action, sizing, and lifecycle coverage is
> complete. Direct CommandMenu catalogue presentation, fuzzy completion,
> geometry, selection, acceptance, and lifecycle coverage is also complete.
> Phase 4's coverage-tooling evaluation, public command, and first baseline are
> complete.
>
> Scope: local test invocation, test-infrastructure regression coverage, test
> failure granularity, and coverage visibility in pi.nvim. This proposal does
> not change runtime behavior, Pi RPC behavior, bundled Extension policy, or the
> requirement for CI to run the full deterministic test gate.

## 1. Summary

Phase 1 provides one explicit Make target for running exactly one test file:

```bash
make test-file TEST=tests/lua/ui/render_spec.lua
```

The same entry point should also run a single bundled Extension test:

```bash
make test-file TEST=tests/extensions/security/permission.test.mjs
```

The target is intended for the short edit-test loop. It must not infer affected
tests from Git changes, and it must not replace the complete `make test` gate.

The command was the first phase of this plan, not the complete test-quality
outcome. Subsequent phases added an automated contract test, split broad Lua
specs along ownership boundaries, improved failure identification, and shipped
coverage visibility without turning a raw percentage into the definition of
correctness.

## 2. Current Behavior

The current Make targets have deliberately broad meanings:

| Command | Current behavior |
| --- | --- |
| `make test` | Runs every Lua spec, every bundled Extension test, and the repository test policy |
| `make test-lua` | Recursively discovers and runs every `tests/lua/**/*_spec.lua` file |
| `make test-file TEST=<path>` | Validates and runs exactly one Lua or bundled Extension test file |
| `make test-extensions` | Recursively runs every `tests/extensions/**/*.test.mjs` file in lexical order |
| `make coverage` | Validates pinned tools, runs the uninstrumented deterministic gate, then writes fresh separate Lua and Extension reports |
| `make smoke` | Checks the installed Pi RPC process and bundled Extension loading without calling a model |
| `make format-check` | Checks formatting under `lua/`, `plugin/`, `tests/`, and repository coverage helpers |

Each Lua spec starts its own headless Neovim process. This isolation is useful,
but repeatedly running the full Lua suite slows down the local feedback loop
when a developer is working on one focused behavior.

`make test-file TEST=<path>` is protected by
`tests/policy/test_file_target_test.sh`. It is a focused feedback command only;
the complete gate still discovers every supported test independently.

The existing suite has several important strengths:

- Lua unit, command, UI, integration, and regression tests are separated by
  responsibility.
- Transcript projection, retention order, history reconstruction, and bounded
  model lifecycles have direct owner-level specs; cross-owner memory and RPC
  ordering remain protected by regression and integration specs.
- TranscriptView buffer ownership, render caching, scroll behavior, semantic
  ranges, scheduling, and image-preparation boundaries have a direct spec; the
  end-to-end Chat performance regression remains in place.
- Bundled Extension policy is tested in Node at the authoritative layer.
- The fake RPC process provides deterministic end-to-end event coverage, while
  smoke tests verify the installed Pi process without calling a model.
- Each Lua spec starts in a separate Neovim process, which prevents state from
  leaking between files.

The remaining known quality gaps are:

- Top-level Lua assertions stop at the first failure in a file and provide no
  test-case-level summary beyond the assertion message.
- The first diagnostic baseline identifies owner-specific behavior gaps; their
  risk ordering and follow-up rules are maintained in `tests/README.md`.

## 3. Goals

- Provide one memorable command for a single Lua or Extension test file.
- Preserve the existing meaning of `make test`, `make test-lua`, and
  `make test-extensions`.
- Validate the requested path before starting a test runner.
- Preserve a selected runner failure as a non-zero Make result without trying a
  fallback runner. GNU Make maps a failed recipe to its own non-zero status.
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

The implemented public interface is:

```text
make test-file TEST=<repository-relative-test-path>
```

`TEST` must name exactly one existing regular file using a repository-relative
path. Absolute paths are not accepted.

Supported path forms are:

| Path pattern | Runner |
| --- | --- |
| `tests/lua/**/*_spec.lua` | `nvim --headless -u tests/minimal_init.lua -l <path>` |
| `tests/extensions/**/*.test.mjs` | `node --test <path>` |

Examples:

```bash
make test-file TEST=tests/lua/client_spec.lua
make test-file TEST=tests/lua/integration/rpc_ui_spec.lua
make test-file TEST=tests/extensions/security/workspace.test.mjs
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
node: tests/extensions/security/permission.test.mjs
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

Phase 1 implementation record, 2026-08-04:

- `test-file` is a phony Make target with fixed shell syntax. The raw `TEST`
  value is transported through a simply-expanded exported variable so Make
  function syntax is not evaluated before validation.
- `tests/policy/test_file_target_test.sh` verifies exact fake-runner arguments,
  top-level and nested Lua routing, Extension routing, invalid paths,
  metacharacter handling, and non-zero failure without runner fallback.
- GNU Make maps a failed recipe to its own documented non-zero exit status; the
  contract therefore cannot return an arbitrary child status such as 23
  unchanged. It verifies zero versus non-zero and selected-runner identity.
- Real focused Lua, nested Lua, and Extension tests passed. The complete suite,
  formatting, CI policy, and installed Pi 0.83.0 smoke gates also passed without
  a model call.

### 8.2 Phase 2: split broad Lua specs by ownership

After the focused target is protected by its own test, split broad specs where a
file currently covers several independent owners. Line count alone is not a
reason to split a test.

Current ownership work is:

- Text, welcome, message, Markdown, tool, and process rendering are split below
  `tests/lua/ui/render/`; `tests/lua/ui/render_spec.lua` retains only the public
  facade and cross-module composition contract.
- Chat coverage is split below `tests/lua/ui/chat/` for facade, shell, activity,
  interaction, registry, and lifecycle behavior. InputArea and CommandMenu have
  standalone specs, while PermissionPanel and WidgetArea retain focused owner
  specs with independent-construction coverage.

This split must follow the ownership and test map in
`docs/lua-architecture.md`. A behavior assigned to `pi.ui.transcript`,
`pi.ui.transcript.view`, or a renderer module belongs with that owner rather
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

Phase 3 harness decision record, 2026-08-04:

- **Decision:** retain dependency-free top-level Lua specs. Keep one Neovim
  process per spec file, file-level `make test-file` selection, descriptive Lua
  assertions, and explicit owner-local cleanup. No suite migration or harness
  dependency is planned.
- **Tested runtimes:** the official Neovim 0.10.4 Linux release with LuaJIT
  2.1.1713484068, and local stable Neovim 0.12.4 with LuaJIT
  2.1.1767980792. The CI matrix continues to name `v0.10.4` and `stable`.
- **Current-suite evidence:** the suite has 50 Lua spec files and 8,888 lines;
  35 specs use protected cleanup. The largest remaining owner specs are
  `transcript_view_spec.lua` (555 lines), `input_spec.lua` (502), and
  `render/tools_spec.lua` (476). Representative `make test-file` runs took
  13 ms for a pure renderer spec, 33 ms for an interactive UI spec, and 108 ms
  for the fake-RPC integration spec on the local stable runtime.
- **Reporting and stability:** the controlled Task 16 failure named the Make
  file prefix, behavior assertion, and original traceback while cleanup still
  removed its probe directory. Four representative async/integration specs ran
  five times on each tested Neovim version (20/20 passes per version). No flaky
  cross-scenario state or demonstrated need to filter several cases inside one
  owner-aligned file was found.

| Candidate | Compatibility and prototype result | Dependency/offline cost | Decision |
| --- | --- | --- | --- |
| Current top-level specs | Passed the existing pure, UI, async, cleanup, traceback, ordering, and non-zero-status contracts on both runtimes. Exact file filtering remains available. | No test dependency, plugin manager, network access, or additional global state. | Selected. File plus behavior diagnostics are adequate. |
| Small repository-owned harness | A temporary named-case prototype passed pure renderer, buffer cleanup, bounded async, exact filtering, forced-failure cleanup, traceback, and exit-status checks on both runtimes. Median prototype startup was about 4 ms. | A production version would require about 100-150 maintained lines across the runner, filter/reporting logic, and direct self-tests. It removes the common `xpcall` shell but not the 35 owner-specific cleanup implementations. | Rejected until real case-filtering or reporting pain justifies owning a framework. |
| `mini.test` from `mini.nvim` v0.17.0 (`a995fe9`) | The pinned temporary prototype passed the same cases on both runtimes. Named failure output, `MiniTest.finally`, exact leaf-case filtering, deterministic execution, and non-zero status worked. Median single-case startup was about 14 ms versus 10-11 ms for the current pure-spec command. | MIT licensed and actively released; supports Neovim 0.9+, needs no plugin manager or transitive runtime dependency, but a pinned checkout was about 21 MiB (`mini.test` itself is 2,385 lines). CI and offline contributors would require a vendored or pre-fetched pinned copy; an unpinned test-time clone is unacceptable. `setup()` also creates the documented global `MiniTest`. | Rejected because its additional case/reporting features do not offset acquisition, pinning, migration, and lifecycle cost for this suite. |

The temporary candidates were outside tracked test paths and were removed after
evaluation. Revisit this decision only if owner specs repeatedly need case-level
filtering, current cleanup boilerplate causes real defects, or file-plus-assert
failure output becomes inadequate. Task 18 copied the concise decision and
test-writing rule into `tests/README.md`.

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

Phase 4 tooling decision record, 2026-08-04:

- **Lua decision:** select LuaCov 0.17.0, pinned to commit
  `b1f9eae400da976b93edb7f94cf5d05f538a0655` under its MIT license. Use its
  debug-hook collector, stats reader, line scanner, and reporter base inside
  Neovim; do not require a system Lua, LuaRocks, Python, CLuaCov, or the HTML
  reporter. The shipped command vendors the exact required upstream Lua files
  plus the license and provenance (56,986 bytes in the evaluated subset),
  because tests must work offline and Neovim embeds its own LuaJIT. LuaCov's
  rockspec-level `datafile` dependency is used by the HTML reporter and is not
  needed by this text-only path. The repository merger explicitly adds zero-hit
  source entries, avoiding LuaFileSystem's `includeuntestedfiles` dependency.
- **Node decision:** use Node's built-in test coverage and a small
  repository-owned reporter. No npm coverage package is needed. The reporter
  must consume the documented `test:coverage` event, retain normal `spec`
  failure diagnostics, filter to `extensions/lib/**/*.mjs`, recompute source-
  only totals, and omit test files, Node internals, global Pi, and generated
  cache paths. Node 20 lacks coverage include/exclude CLI flags, so relying on
  the newer flags would violate the supported-major contract.
- **Version boundary:** `--experimental-test-coverage` works with `--test`
  beginning in Node 20.1.0. It passed on Node 20.20.2 and local Node 22.23.1;
  Node 20.0.0 rejected the combination with exit 9. The coverage command makes
  Node >=20.1 explicit while normal tests retain their Node 20 major boundary.
  Raw `NODE_V8_COVERAGE` worked on 20.0.0 but was
  rejected as the implementation path because it would require pi.nvim to own
  a V8 range-to-line/branch merger. Normal tests remain compatible with the
  existing Node 20 major boundary.

Primary references are the [LuaCov 0.17 documentation](https://lunarmodules.github.io/luacov/),
its pinned upstream source, and the [Node 20 test-runner documentation](https://nodejs.org/download/release/latest-v20.x/docs/api/test.html).
LuaCov provides line coverage only; Node reports line, branch, and function
coverage.

| Runtime | Prototype result |
| --- | --- |
| Neovim 0.10.4 / LuaJIT 2.1.1713484068 | Pure renderer and buffer/window UI specs passed under instrumentation in separate processes. Their unique stats merged exactly, the summary used original repository paths, a controlled failure returned 1, and `performance_spec.lua` passed both normally and instrumented. |
| Neovim 0.12.4 / LuaJIT 2.1.1767980792 | The same focused contracts passed. All 50 instrumented Lua specs passed and merged into one report. |
| Node 20.20.2 | One policy file and all five Extension test files passed with source-only line/branch/function summaries; a controlled failure retained its traceback and exit 1. |
| Node 22.23.1 | The same Extension results and failure behavior passed. Totals matched Node 20.20.2 exactly. |
| Node 20.0.0 | Normal tests and raw V8 output worked, but built-in test reporting rejected coverage plus `--test`; unsupported for the coverage command. |

The two focused Neovim processes recorded 1,959 and 8,320 line-hook hits on
each Neovim version. The merger produced exactly 10,279 hits, proving that one
process did not overwrite the other. It normalized absolute debug paths to
`lua/pi/...` and `plugin/pi.lua`, and explicit zero entries made unloaded source
files visible. `plugin/pi.lua` was sourced naturally after the coverage init
prepended the repository runtime path, and remains a separate report row.

The stable full-suite spike merged 50 fresh process files (about 1.4 MiB) into
a 37 KiB stats file. LuaCov's default source listing was 520 KiB, so it is not
the selected report format. A custom summary reporter produced the same
7,533-hit/1,063-missed result in 2.6 KiB without source contents, absolute
paths, tests, prompts, secrets, or dependency code. Its provisional diagnostic
total was 87.63% line coverage. The shipped baseline below supersedes this
temporary result.

Node automatically merged the five Extension test subprocesses. Both accepted
Node versions reported the same provisional helper totals: 96.58% lines,
87.36% branches, and 92.86% functions across all eight
`extensions/lib/**/*.mjs` files. The custom reporter removed test files from
both rows and aggregate percentages.

TypeScript entry-point percentages are explicitly rejected. Production Pi/jiti
smoke emitted V8 script URLs ending in the four original `.ts` paths but no
source-map cache. A direct jiti probe reported an uninvoked six-line entry as
100% covered and placed a `todo.ts` load error at generated position `1:222`.
Those numbers describe transformed code under an original-looking filename,
not trustworthy TypeScript lines. `extensions/*.ts` therefore remain covered
by the installed-Pi loading smoke and behavior in their imported policy
helpers, but are excluded from percentage totals. Coverage must not replace
`make smoke`.

Measured wall-clock overhead was:

| Scope | Normal | Instrumented | Increase |
| --- | ---: | ---: | ---: |
| Stable pure spec, 50 processes | 0.48 s | 0.74 s | 54% |
| Stable UI spec, 25 processes | 0.37 s | 0.72 s | 95% |
| Stable full Lua suite, 50 specs | 2.79 s | 42.96 s | 1,440% |
| Stable `performance_spec.lua` | 0.15 s | 0.16 s | 7% |
| Neovim 0.10 `performance_spec.lua` | 0.14 s | 0.15 s | 7% |
| Node 20 Extension suite, 20 runs | 1.07 s | 1.59 s | 49% |
| Node 22 Extension suite, 20 runs | 2.98 s | 3.61 s | 21% |

Lua's full-run cost is concentrated in high-volume client paths under the line
debug hook. Coverage remains a separate diagnostic target. The performance
spec's assertions passed on both Neovim versions with about 7% overhead, so it
will remain instrumented; there is no evidence-based exclusion. Normal
`make test` remains uninstrumented.

The shipped workflow uses a fresh, repository-local layout:

```text
coverage/lua/raw/
coverage/lua/merged.stats
coverage/lua/summary.txt
coverage/extensions/summary.txt
```

The generated `coverage/` root is narrowly ignored. The helper resolves the
repository root, validates that the cleanup target is exactly its non-symlink
`coverage/` child, clears it at the beginning of every run, assigns a unique
Lua stats file per spec, merges only the current manifest, removes raw files
after a successful merge, and retains only bounded summaries. The command does
not fetch from the network.

One pre-existing compatibility failure was discovered outside the tooling:
the uninstrumented Neovim 0.10.4 suite formats `compact_count(1250)` as `1.3k`
while local stable formats it as `1.2k`, causing `shared_owners_spec.lua` to
fail before coverage starts. Commit `5fbc944` replaced runtime-dependent decimal
formatting with protected half-even rounding and restored the full Neovim 0.10.4
gate. The coverage workflow runs the normal uninstrumented gate first so it
cannot conceal this kind of baseline failure.

Phase 4 implementation record, 2026-08-04:

- `make coverage` validates the vendored LuaCov hashes and Node >=20.1, runs
  `make test` uninstrumented, then collects one fresh stats file from each of 50
  isolated Neovim processes. It merges all 57 Lua production files, including
  explicit zero-hit entries, and runs all five authoritative Extension test
  files in one Node coverage command.
- The shipped Neovim 0.12.4 / LuaJIT 2.1.1767980792 baseline is 7,539 hit and
  1,063 missed executable lines, or 87.64%. The Node 22.23.1 helper baseline is
  96.58% lines, 87.36% branches, and 92.86% functions. Scope, blind spots, and
  risk-ordered follow-ups are recorded in `tests/README.md`.
- Two complete public-command runs produced identical summaries. A stale probe
  inserted before the second run was removed, current-only manifests still
  merged exactly 50 artifacts, and no raw or manifest file survived success.
- A controlled coverage-only failure passed the uninstrumented prerequisite,
  failed the first instrumented spec with its original traceback, and made GNU
  Make return non-zero. The temporary failure was restored immediately.
- Instrumentation exposed a weak-reference flaw in `registry_spec.lua`: its
  temporary Chat entry could be collected before the resize assertion. The
  spec now retains the same strong owner reference that a real Chat has; normal
  and instrumented forms both pass. Production Registry behavior was unchanged.
- Generated reports remain ignored and no CI percentage threshold was added.

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
