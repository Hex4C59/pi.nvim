# Test Guide

This directory contains pi.nvim's deterministic tests. They do not call a
model, require authentication, or fetch network resources. The fake RPC process
drives protocol ordering and cross-owner UI workflows, while bundled Extension
policy is tested at its authoritative TypeScript/JavaScript layer. Each Lua spec
runs in a fresh headless Neovim process. Tests against the installed `pi`
process are kept in the separate smoke target and also do not call a model.

See [AGENTS.md](../AGENTS.md) for authoritative ownership and security rules and
[Lua Frontend Architecture](../docs/lua-architecture.md) for frontend module
boundaries. Bundled guards are trusted in-process guardrails, not a sandbox.

## Commands

Run commands from the repository root.

| Command | Scope | Intended use |
| --- | --- | --- |
| `make test-file TEST=<path>` | Exactly one existing Lua `*_spec.lua` or Extension `*.test.mjs` file | Focused local loop |
| `make test-lua` | Every recursively discovered `tests/lua/**/*_spec.lua` file, one Neovim process per file | Lua subsystem gate |
| `make test-extensions` | Every recursively discovered `tests/extensions/**/*.test.mjs` file | Bundled Extension gate |
| `make test` | All Lua, Extension, and repository policy tests | Completion and CI gate |
| `make coverage` | Uninstrumented `make test`, then fresh Lua and Extension coverage reports | Diagnostic coverage baseline |
| `make coverage-clean` | Only the validated repository-local `coverage/` directory | Remove generated reports |
| `make format-check` | StyLua validation for `lua/`, `plugin/`, `tests/`, and repository coverage helpers | Formatting gate |
| `make smoke` | Installed Pi RPC startup and bundled Extension loading, without model calls | Installed compatibility gate |
| `make ci-policy-check` | GitHub Actions immutable-pin policy | CI workflow gate |

Examples:

```bash
make test-file TEST=tests/lua/protocol_spec.lua
make test-file TEST=tests/lua/ui/chat/facade_spec.lua
make test-file TEST=tests/extensions/security/permission.test.mjs
```

`test-file` accepts one repository-relative file path. It does not infer tests
from Git changes and never replaces the complete `make test` gate. `make test`
does not include formatting or installed-process smoke checks; run those when
the change scope requires them.

`make coverage` additionally requires Node 20.1 or newer. Normal tests retain
their Node 20 major-version boundary. Coverage is deliberately separate from
the focused loop and is not part of CI.

## Directory Map

| Directory | Responsibility |
| --- | --- |
| `tests/lua/` | Focused Lua behavior for protocol, client, runtime, config, context, and shared helpers |
| `tests/lua/commands/` | Native command adapters, catalogue dispatch, RPC limitations, and session commands |
| `tests/lua/ui/` | Neovim UI component, composition, transcript, renderer, and image behavior |
| `tests/lua/ui/chat/` | Chat facade, shell/layout, interaction, registry, activity, and lifecycle behavior |
| `tests/lua/ui/render/` | Text, welcome, message, Markdown, tool, and process render owners |
| `tests/lua/ui/transcript/` | Pure transcript projection, retention ordering, and history reconstruction |
| `tests/lua/ui/image/` | Image facade, source, preview, scheduler, backend, and window owners |
| `tests/lua/integration/` | Fake-RPC and cross-owner workflows |
| `tests/lua/regression/` | Output memory budgets and rendering/performance regressions |
| `tests/extensions/` | Authoritative bundled Extension behavior and policy |
| `tests/extensions/security/` | Permission, path, workspace, and session-root policy owners |
| `tests/fixtures/` | Deterministic fake processes and test data |
| `tests/smoke/` | Installed Pi RPC and Extension loading checks without model calls |
| `tests/policy/` | Repository architecture, dependency, runner, and CI policy contracts |

## Critical-Path Ownership

| Owner | Primary focused tests | Cross-owner regression/integration | Smoke requirement |
| --- | --- | --- | --- |
| LF JSONL parser | `tests/lua/protocol_spec.lua` | `tests/lua/client_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | `tests/smoke/client_smoke.lua` when installed protocol compatibility changes |
| RPC client and subprocess lifecycle | `tests/lua/client_spec.lua` | `tests/lua/integration/init_spec.lua`, `tests/lua/integration/image_rpc_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | `tests/smoke/client_smoke.lua` |
| Runtime event projection and per-project state | `tests/lua/runtime_spec.lua` | `tests/lua/integration/init_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | When an installed capability is involved |
| Commands and catalogue | `tests/lua/commands/`, `tests/lua/shared_owners_spec.lua` | `tests/lua/integration/rpc_ui_spec.lua` | When an installed RPC command capability is involved |
| Renderer text/welcome/messages/Markdown/tools/process | `tests/lua/ui/render/`, `tests/lua/ui/render_spec.lua` | `tests/lua/ui/chat/facade_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | None normally |
| Transcript projection, retention, history, and model | `tests/lua/ui/transcript/`, `tests/lua/ui/transcript_spec.lua` | `tests/lua/regression/output_budget_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | None normally |
| TranscriptView buffer, cache, ranges, and scheduling | `tests/lua/ui/transcript_view_spec.lua` | `tests/lua/regression/performance_spec.lua`, `tests/lua/regression/output_budget_spec.lua` | None normally |
| InputArea and CommandMenu | `tests/lua/ui/input_spec.lua`, `tests/lua/ui/command_menu_spec.lua` | `tests/lua/ui/chat/shell_spec.lua`, `tests/lua/ui/chat/interaction_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | None normally |
| Chat facade, shell, registry, interactions, and lifecycle | `tests/lua/ui/chat/` | `tests/lua/regression/performance_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | None normally |
| Dialog and permission presentation | `tests/lua/ui/dialog_spec.lua`, `tests/lua/ui/permission_spec.lua` | `tests/lua/integration/rpc_ui_spec.lua` | `tests/smoke/extensions_smoke.mjs` when installed UI behavior changes |
| Permission mode, approvals, and allow/block decisions | `tests/extensions/security/permission.test.mjs` | `tests/lua/ui/permission_spec.lua` remains a separate presentation test | `tests/smoke/extensions_smoke.mjs` |
| Workspace and session-root enforcement | `tests/extensions/security/workspace.test.mjs`, `tests/extensions/security/paths.test.mjs`, `tests/extensions/security/session-root.test.mjs` | Lua session/preflight tests are defense in depth only | `tests/smoke/extensions_smoke.mjs` |
| Todo workflow and session reconstruction | `tests/extensions/todo-list.test.mjs` | `tests/lua/ui/widget_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` cover presentation separately | `tests/smoke/extensions_smoke.mjs` |
| Image data, source, preview, scheduler, backend, and window | `tests/lua/ui/image/`, `tests/lua/ui/image_chat_spec.lua`, `tests/lua/ui/markdown_image_spec.lua` | `tests/lua/integration/image_rpc_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` | Capability-dependent `tests/smoke/client_smoke.lua` |
| Focused runner and repository policies | `tests/policy/test_file_target_test.sh`, other `tests/policy/*_test.sh` files | Included by `make test` | `make ci-policy-check` for workflow pins |

The table identifies test ownership, not line or branch coverage. Security state
and decisions stay authoritative in Extensions; Lua tests cover only their
native Neovim presentation and adapter behavior.

## Change-To-Test Matrix

| Change | Focused checks during development | Completion checks |
| --- | --- | --- |
| JSONL parser or Client | Protocol/client specs and the relevant fake-RPC integration | `make test`; client smoke for installed compatibility changes |
| Runtime event projection | Runtime spec, related command spec, and RPC UI integration | `make test` |
| Command adapter or catalogue | Matching `tests/lua/commands/` spec and shared catalogue/RPC UI coverage | `make test` |
| Renderer owner | Matching `tests/lua/ui/render/` spec and Chat facade | `make test`, `make format-check` |
| Transcript projection or budget | Matching transcript owner spec and output-budget regression | `make test` |
| TranscriptView or Chat UI component | Direct component spec plus Chat shell/facade/lifecycle as relevant | `make test`, `make format-check` |
| Image pipeline or placement | Matching image owner spec and image RPC integration | `make test`; smoke when installed capability changes |
| Extension permission/workspace/session policy | Authoritative Node policy test; Lua UI test only if presentation also changes | `make test`, `make smoke` for Extension API/loading changes |
| Extension todo workflow | Todo Extension test and widget/RPC UI tests when presentation changes | `make test`, `make smoke` for Extension API/loading changes |
| GitHub Actions workflow | `make ci-policy-check` and policy tests | `make test`, `make ci-policy-check` |
| Broad refactor | Owner-focused tests throughout the work | `make test`, `make format-check`, and scope-dependent `make smoke` |

## Writing Tests

- Put Lua specs under `tests/lua/` with a recursively discoverable
  `*_spec.lua` name. Put bundled Extension tests under `tests/extensions/` with
  a `*.test.mjs` name.
- Name files by the state or behavior owner. Keep transport, event projection,
  rendering, UI composition, and Extension policy assertions at their owning
  layers.
- Keep each Lua file independently runnable in a fresh Neovim process. Use the
  dependency-free top-level Lua style and end with one unique stable
  `<owner>_spec: ok` label after cleanup succeeds.
- Use structured fixtures and events. Do not parse rendered prose to recover
  security, session, queue, tool, or image semantics.
- Give every assertion a behavior-oriented diagnostic. Keep actual values
  bounded and never dump Base64 images, full RPC frames, large tool output,
  environment variables, or secrets.
- Bound every asynchronous wait and name the state being awaited. Do not use an
  arbitrary sleep as a lifecycle assertion.
- Save and restore patched globals/functions. Protect resource-owning specs
  with `xpcall(..., debug.traceback)`, restore globals first, then stop jobs and
  timers, close windows, delete buffers, and remove validated temporary paths.
  Re-raise the original traceback after cleanup.
- Keep cleanup helpers local to the spec that owns the fixture. There is no
  shared Lua test harness or shared mutable fixture module.
- Do not call a model, require authentication, or fetch from the network.
- Do not weaken an authoritative Extension policy test and compensate with a
  Lua UI test. Add coverage at both layers when policy and presentation change.
- Use `make test-file TEST=<path>` while editing. Run `make test` before
  completion, plus formatting and smoke gates required by the change scope.

## Harness Decision

The suite intentionally retains dependency-free top-level Lua specs. Owner
decomposition, the Make file prefix, descriptive assertions, protected local
cleanup, and one-process-per-file isolation provide adequate diagnostics. No
demonstrated workflow currently requires filtering below the file level.

The supported filtering unit is exactly one file through
`make test-file TEST=<path>`. Cleanup remains explicit beside each fixture; no
repository-owned or external harness is loaded. Reconsider this only if repeated
case-level filtering needs or cleanup defects provide concrete evidence that a
harness would remove more complexity than it adds.

## Coverage

Run the complete diagnostic workflow from the repository root:

```bash
make coverage
```

The command validates its pinned tools before running anything, runs the normal
`make test` gate without instrumentation, clears only a resolved non-symlink
`coverage/` child of the repository, and then collects fresh data. It needs no
model, authentication, installed Pi mutation, package installation, network
fetch, system Lua, Python, or LuaRocks. A test failure remains non-zero and the
next invocation discards incomplete or stale artifacts.

LuaCov 0.17.0 is vendored at commit
`b1f9eae400da976b93edb7f94cf5d05f538a0655`; the command verifies every
selected upstream source file and its MIT license by SHA-256 before collection.
Each Lua spec retains its own Neovim process and unique stats file. The merger
accepts only the current invocation manifest, normalizes paths to the original
repository sources, explicitly adds unloaded modules with zero hits, and
deletes raw per-process files after a successful report.

Node uses its built-in test coverage and one repository reporter. All
`tests/extensions/**/*.test.mjs` files run in one test command so Node can merge
their worker coverage while preserving normal `spec` failures. Node 20.1 is the
minimum coverage version because 20.0 rejects `--test` with
`--experimental-test-coverage`.

| Report | Included source | Excluded source |
| --- | --- | --- |
| `coverage/lua/summary.txt` | `lua/pi/**/*.lua`, `plugin/pi.lua` | Tests, fixtures, vendored tooling, generated data |
| `coverage/lua/merged.stats` | Current-run normalized LuaCov stats | Stale and raw process artifacts |
| `coverage/extensions/summary.txt` | `extensions/lib/**/*.mjs` | Tests, Node internals, global Pi, generated cache, `extensions/*.ts` |

The generated root is ignored by Git. `make coverage-clean` removes it through
the same exact-path and symlink checks. Reports are bounded summaries and do not
copy source lines, prompt contents, Base64 data, test fixtures, or absolute
repository paths.

### Baseline

The first shipped baseline was recorded on 2026-08-04 with Neovim 0.12.4,
LuaJIT 2.1.1767980792, Node 22.23.1, vendored LuaCov 0.17.0, and Node's built-in
test coverage. Two consecutive complete runs produced identical totals after a
deliberate stale artifact was placed in `coverage/` before the second run.

| Owner | Result |
| --- | --- |
| Lua frontend | 7,539 hit and 1,063 missed executable lines: 87.64% line coverage |
| Extension helpers | 96.58% lines, 87.36% branches, 92.86% functions |

The performance regression spec runs first without instrumentation as part of
the normal gate and then under LuaCov. It passed in both modes and contributes
coverage; the diagnostic line hook does not redefine its uninstrumented timing
contract.

Interpret the baseline by ownership and risk:

- The authoritative permission helper is the highest-priority Extension gap at
  93.64% lines, 84.56% branches, and 84.62% functions. Follow-up tests should
  target unverified fail-closed response and transition branches, not execute
  lines without asserting the decision.
- RPC-critical Lua owners remain incomplete: `client.lua` is 80.20%,
  `runtime.lua` 81.79%, and `protocol.lua` 92.41%. Follow-ups should prioritize
  subprocess errors, correlation/queue limits, malformed frames, and final
  cleanup ordering.
- Dialog and permission presentation are 84.62% and 92.34%; remaining work
  should focus on cancellation, malformed UI responses, and teardown paths
  while keeping decisions authoritative in the Extension.
- Transcript and TranscriptView owners exceed 94% line coverage, but explicit
  memory, timer, and post-destroy behavior tests remain more meaningful than
  percentage gains.
- Native picker/command integration is intentionally sparse in
  `commands/model.lua`, `commands/session.lua`, `commands/ui.lua`, and
  `clipboard.lua`. Environment-independent capability-limit and cleanup tests
  are useful; plugin-specific happy paths do not justify weakening isolation.
- Image source/backend branches depend on optional executables and UI backends.
  Add deterministic adapter/error tests where behavior matters rather than
  importing host state into the default suite.

LuaCov reports lines only, so Lua branch and function coverage remain a blind
spot. Trusted TypeScript entry points under `extensions/*.ts` are excluded
because Pi's jiti transformation did not provide reliable source-mapped V8
positions; `make smoke` remains their installed-Pi loading check. Coverage also
does not replace RPC ordering, security, lifecycle, memory-budget, performance,
or smoke assertions. No percentage threshold is enforced in CI. Reproduce the
baseline with exactly `make coverage` after relevant source or behavior-test
changes.

## Plan Closeout

The focused-test and modular-architecture plans were closed on 2026-08-04 with
Neovim 0.12.4 / LuaJIT 2.1.1767980792, Node 22.23.1, GNU Make 4.4.1,
StyLua 2.5.2, and installed Pi 0.83.0. Pi resolved from
`/home/hex4c59/.local/bin/pi` to the user-level package CLI. No verification
command called a model, required credentials, fetched dependencies, or changed
the installed Pi package.

### Inventory And Timing

| Measurement | Initial Task 01 baseline | Closeout |
| --- | ---: | ---: |
| Lua spec files | 31 | 50, 8,966 lines |
| Extension test files | 4 | 5, containing 24 Node test cases |
| Repository policy files | 2 | 4 |
| Smoke files | 2 | 2 |
| `make test` wall time | 2.46 s | 4.20 s |
| `make format-check` wall time | 0.04 s | 0.04 s |
| `make smoke` wall time | 2.51 s | 2.43 s |

The full suite is about 71% slower because it starts 19 additional isolated
Neovim spec processes and runs additional Extension and policy owners. The
tradeoff is accepted: failures now identify a narrower module/lifecycle owner,
while the complete suite remains only a few seconds. Representative closeout
focused times were below 0.01 s for `protocol_spec.lua`, 0.01 s for the process
renderer, 0.16 s for Chat lifecycle, 0.08 s for fake-RPC UI integration, and
0.14 s for the authoritative permission Extension test.

An irrelevant exported `TEST` value did not narrow the complete gate: its
prefix inventory remained exactly 50 Lua, 5 Extension, and 4 policy files.
`make coverage` took 46.74 s, merged 50 fresh Lua artifacts across all 57 Lua
production files, emitted the documented separate baseline totals, and left no
tracked generated report. `make ci-policy-check`, formatting, deterministic
tests, and installed-process smoke all passed. The official Neovim 0.10.4 suite
also passed during the preceding compatibility verification; CI continues to
run the full gate on `v0.10.4` and stable.

Task 01 and closeout had no baseline failures. Controlled runner and coverage
failures used during implementation now report the selected Make prefix, the
behavior assertion or original traceback, and a non-zero result while protected
cleanup still runs; this is more actionable than the former broad owner files.

### Assertion And Ownership Audit

Renderer decomposition retained the public facade and increased owner-focused
coverage from 145 assertions in the old aggregate to 275 across the facade and
six renderer specs. Chat already had an initial six-file component split before
its final decomposition; it increased from 143 assertions before the shell task
to 253 across the current facade, shell, interaction, registry, and lifecycle
owners. The old activity fixture was removed only after its timer and cleanup
cases moved into lifecycle/facade coverage. Reviewed repeated fixture strings
are intentional facade/owner boundary inputs, not copied full scenarios.

Discovery finds every supported suffix recursively, no test path is a symlink,
and no helper uses a supported test suffix. Resource-owning specs retain local
protected cleanup for timers, jobs, temporary files, windows, buffers, and
patched globals. The ownership map above was checked against imports and
fixtures: Pi session/model/queue behavior enters through RPC state; permission
decisions and approvals remain in Extension tests; Lua permission tests cover
only display, response, and fail-closed cancellation; Transcript and View keep
separate model/projection resources; and UI/image owners release only the
resources they create.

Residual risks remain explicit:

- Top-level Lua files stop at their first failed assertion and support filtering
  only by file. The retained dependency-free harness remains appropriate until
  repeated case-level filtering or cleanup defects justify its cost.
- Local closeout ran on stable Neovim. Minimum-version behavior is protected by
  the earlier official 0.10.4 run and CI matrix, not by this one local timing.
- Lua coverage has no branch/function signal, transformed TypeScript entry
  points remain excluded, and the risk-ranked behavior gaps in the baseline
  still require focused assertions rather than a percentage threshold.
- Installed smoke verifies RPC startup and Extension loading without a model;
  it cannot prove manual terminal layout, optional image backend, or long-lived
  authenticated model workflows.
