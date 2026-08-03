# Modular Architecture Improvement Plan

> Status: In progress. Tasks 01 through 03 were completed on 2026-08-04; Tasks
> 04 through 08 remain proposed.
>
> Scope: internal Lua frontend boundaries, bundled Extension policy modules,
> test ownership, dependency enforcement, and durable architecture
> documentation.
>
> Target: move pi.nvim from a well-layered project with several large,
> tightly-coupled internal modules to a project whose directory structure,
> module APIs, tests, and automated policies all express the same ownership
> model.

## 1. Outcome

The work is complete when all of the following are true:

1. Every runtime state value has one documented owner.
2. Cross-layer callers use public module APIs instead of component fields.
3. `pi.ui.chat`, `pi.ui.image`, `pi.ui.transcript`, and `pi.ui.render` remain
   stable facades while their internal implementations are organized by one
   reason to change.
4. Bundled Extension entry files remain thin, and each authoritative security
   policy has a focused internal owner.
5. Test files mirror production ownership closely enough that one module can be
   changed and verified without running an unrelated broad UI scenario.
6. Automated policy tests enforce the documented dependency direction and
   reject known facade leaks.
7. Proposed task documents are removed after their durable results have been
   captured in code, tests, `README.md`, or current architecture documentation.
8. All deterministic tests, formatting checks, installed-process smoke tests,
   and CI policy checks pass.

This plan does not define excellence by a maximum line count. File size is a
review signal only. Cohesion, dependency direction, state ownership, and focused
verification are the acceptance criteria.

## 2. Initial Baseline

At the start of the plan, the top-level ownership was sound:

```text
plugin/       Neovim command and autocmd registration
lua/pi/       RPC adapter, runtime projection, commands, and native UI
extensions/   Authoritative Pi workflow and security policy
tests/        Lua, Extension, integration, regression, policy, and smoke tests
docs/         Shipped architecture, capability gaps, and proposed work
scripts/      Repository and CI policy helpers
```

The main structural debt is concentrated below these correct top-level
boundaries:

| Area | Current signal | Structural concern |
| --- | ---: | --- |
| `lua/pi/ui/chat.lua` | 1,043 lines, 76 methods | Composition, global UI lifecycle, layout, activity, facade delegation, attachments, and interaction live together |
| `lua/pi/ui/transcript.lua` | 1,002 lines, 39 methods | Projection, resource accounting, retention, tool lifecycle, Bash streaming, and history rebuilding live together |
| `lua/pi/ui/image.lua` | 846 lines, 46 functions | Source validation, cache I/O, format parsing, preview rendering, process scheduling, localization, and accounting live together |
| `extensions/lib/security-policy.mjs` | 466 lines | Shared path helpers and three separately-owned security policies live together |
| `tests/lua/ui/chat_spec.lua` | 601 lines | Several component and lifecycle owners share one failure boundary |
| `tests/lua/ui/render_spec.lua` | 528 lines | Focused renderer modules are still verified through one broad facade spec |
| `docs/testing-improvements/` | 21 task files; first 4 completed | Temporary planning material outweighs durable test guidance |

At the start of the plan, known facade leaks included:

- `lua/pi/runtime.lua` mutating `chat.transcript.history_loaded`;
- `lua/pi/commands/permission.lua` reading `chat.permission_area`;
- `lua/pi/commands/ui.lua` reading Chat display fields directly;
- UI components reaching through Chat to sibling components such as
  `chat.input_area` and `chat.transcript_view`; and
- runtime-owned queue and command state being attached dynamically to Client
  objects.

Before Task 01 starts, record the exact output of:

```bash
git status --short
make test
make format-check
make smoke
make ci-policy-check
```

The baseline must distinguish existing failures from regressions. No task may
weaken a failing test to make an architectural move pass.

## 3. Non-Goals

This plan does not:

- change Pi core, Pi RPC, or Extension UI protocol semantics;
- move authoritative permission, workspace, session, tool, queue, model, or
  compaction state into Lua;
- redesign the visible chat UI;
- change public Neovim commands, user configuration, or keybindings;
- add a general dependency-injection framework or class framework;
- split files solely to satisfy an arbitrary line limit;
- preserve private module paths when no external contract documents them; or
- use model calls, authentication, or paid tokens during deterministic tests.

## 4. Architectural Rules

All implementation tasks must preserve these rules.

### 4.1 Stable Facades

The following require paths remain stable:

```text
pi
pi.client
pi.protocol
pi.runtime
pi.ui.chat
pi.ui.image
pi.ui.transcript
pi.ui.render
```

A facade may compose internal modules and expose compatibility functions. It
must not become the implementation location for every new behavior.

### 4.2 Dependency Direction

```text
plugin -> init -> commands -> runtime -> client -> protocol
                             -> chat facade -> UI components

render facade -> render internals
chat facade   -> chat/transcript/image/component internals

Extension entry -> its authoritative policy module -> shared pure helpers
```

Allowed shared leaves include `pi.config`, `pi.message`, `pi.format`,
`pi.permission_mode`, and narrowly-scoped pure helpers. A lower layer must not
require a higher layer.

### 4.3 Component Contracts

`Chat` is the composition root for one project's native UI. External modules may
use documented Chat methods and immutable project identity, but must not read or
write these implementation fields:

```text
transcript
transcript_view
input_area
command_menu
permission_area
widget_area
image_backend
image_preview
```

Child components receive only the providers and actions they use. They must not
receive the complete Chat object merely for convenience, and they must not reach
through Chat to a sibling component.

### 4.4 State Ownership

- `Client` owns process transport, parser state, request correlation, and the
  RPC-reported session mirror.
- `Runtime` owns per-project orchestration, display correlation queues, command
  catalogues, refresh-in-flight flags, and direct-RPC Bash request state.
- `Chat` owns display mirrors and component composition.
- Each UI component owns its buffers, windows, timers, queues, and local
  presentation state.
- `Transcript` owns bounded structured display items and resource accounting,
  never Pi's authoritative session.
- Extensions own permission mode, approvals, workspace enforcement, plan-mode
  tool restrictions, and session-root enforcement.

## 5. Target Structure

The exact private filenames may change during implementation when a better
cohesive boundary is demonstrated, but the resulting ownership should resemble:

```text
lua/pi/
  client.lua
  protocol.lua
  runtime.lua
  commands/
  ui/
    chat.lua                       stable facade and composition root
    chat/
      registry.lua                 instances, global autocmds, shared animation
      shell.lua                    main window lifecycle and responsive layout
    transcript.lua                 stable model facade and event lifecycle
    transcript/
      projection.lua               bounded user/assistant/tool projections
      retention.lua                pure retention decisions and accounting helpers
      history.lua                  history-to-display projection
      view.lua                     buffer, render cache, ranges, and placements
    image.lua                      stable image facade
    image/
      source.lua                   MIME, decoding, cache, dimensions, validation
      preview.lua                  terminal-color preview conversion/highlights
      scheduler.lua                debounce, concurrency, timeout, cancellation
      backend.lua                  backend selection and status
      backends/
        snacks.lua
      window.lua                   enlarged image preview lifecycle
    render.lua
    render/                        existing focused renderer modules
    input.lua
    command_menu.lua
    permission.lua
    widget.lua

extensions/
  permission-gate.ts              thin Pi entry
  workspace-guard.ts              thin Pi entry
  session-root-guard.ts           thin Pi entry
  lib/
    security/
      path.mjs                    canonical path and containment helpers
      permission.mjs              permission mode and approval controller
      workspace.mjs               read-only workspace policy
      session-root.mjs            session header and root-switch policy
    todo-list.mjs

tests/
  lua/
    commands/
    integration/
    regression/
    ui/
      chat/
      image/
      render/
      transcript/
  extensions/
    security/
  policy/
  smoke/
```

Do not create an empty directory or a one-function module only to match this
tree. Each extracted module must own a meaningful policy, lifecycle, or pure
transformation.

## 6. Task Sequence

| Task | Status | Purpose | Depends on |
| --- | --- | --- | --- |
| 01 | Completed | Record contracts and strengthen architecture policy coverage | none |
| 02 | Completed | Seal Chat and Runtime ownership boundaries | 01 |
| 03 | Completed | Decouple and split the Chat shell | 02 |
| 04 | Proposed | Organize the image subsystem | 02 |
| 05 | Proposed | Organize Transcript projection, retention, history, and view | 02, 04 |
| 06 | Proposed | Split bundled security policy owners | 01 |
| 07 | Proposed | Align test structure and focused execution | 03, 04, 05, 06 |
| 08 | Proposed | Consolidate durable documentation and close the plan | 07 |

Tasks 03, 04, and 06 may be delivered independently after their prerequisites.
Task 05 follows Task 04 because Transcript image accounting must depend on the
stable image facade rather than private image implementation details.

## 7. Task 01: Contracts And Policy Guardrails

### Goal

Turn the architecture document from guidance into an enforceable contract before
moving implementation files.

### Changes

1. Record the current literal Lua `require` graph and identify every intentional
   cross-layer edge.
2. Expand `tests/policy/lua_dependency_policy_test.sh`, or replace it with a
   focused policy helper, so it enforces at least:
   - protocol does not depend on client, runtime, commands, or UI;
   - client does not depend on runtime, commands, or UI;
   - renderer internals do not depend on runtime, client, or commands;
   - command modules do not require concrete UI modules;
   - the checked literal require graph contains no cycle; and
   - exceptions are explicit and documented rather than silently ignored.
3. Add a facade-leak policy that rejects known component-field access outside the
   Chat composition implementation. Start with the component names listed in
   section 4.3.
4. Add or update an ownership table that maps every mutable per-project value to
   Client, Runtime, Chat, Transcript, a UI component, or an Extension.

### Tests

The policy test must include fixtures proving it fails for a forbidden edge, a
cycle, and a Chat component-field leak. Testing only the current repository's
happy path is insufficient.

### Exit Criteria

- Current intentional dependencies pass.
- A deliberately forbidden dependency fails with a precise file and rule.
- New exceptions require editing one reviewed allowlist.
- The policy does not mistake comments or documentation for executable requires.

### Implementation Record

Completed on 2026-08-04 against working-tree base `7b4e626`.

- Added `scripts/check-lua-architecture.mjs`, which tokenizes executable Lua,
  enforces layer rules, detects unapproved literal-require cycles, and checks a
  shrinking Chat facade-leak budget.
- Expanded `tests/policy/lua_dependency_policy_test.sh` with isolated fixtures
  for a forbidden command-to-UI edge, a require cycle, a Chat field leak, and
  comment/string false positives.
- Documented Runtime orchestration ownership and every temporary dependency or
  facade exception in `docs/lua-architecture.md`.
- Pulled the focused-test prerequisite forward from the older test-quality plan:
  `make test-file` and its independent Make contract test are implemented and
  documented, while broad spec decomposition remains in Task 07.
- `make test`, `make format-check`, `make smoke`, and
  `make ci-policy-check` all passed without a model call.

## 8. Task 02: Seal Chat And Runtime Boundaries

### Goal

Make `Chat` a real facade and keep Runtime-owned state out of Client and UI
component internals.

### Changes

1. Add narrow Chat methods for the currently leaked operations, including:
   - detecting an active permission request;
   - resetting the local projection before session history reload;
   - reading the current layout choice;
   - reading whether detailed process rendering is enabled; and
   - returning a read-only display-state snapshot where several consumers need
     the same values.
2. Replace direct accesses in `runtime.lua`, `commands/permission.lua`, and
   `commands/ui.lua` with those methods.
3. Treat project root as an explicitly documented immutable Chat identity, or
   expose it through one getter. Do not leave its status ambiguous.
4. Introduce one Runtime-owned per-project record, or equivalent side tables,
   for:
   - display correlation queue;
   - discovered command map;
   - stats refresh in-flight state; and
   - direct RPC Bash request ID.
5. Stop attaching those orchestration fields dynamically to Client instances.
6. Preserve request ordering, prompt image restoration, client replacement, and
   stop/destroy semantics.

### Tests

- Add focused facade tests for every new Chat method.
- Extend runtime tests for session reload, display correlation, failed prompts,
  stats de-duplication, direct Bash abort, and client replacement.
- Add a policy assertion that Runtime and commands no longer access Chat
  component fields.

### Exit Criteria

- Only the Chat composition implementation knows Chat component fields.
- Client fields are declared and owned by Client; Runtime orchestration state is
  declared and owned by Runtime.
- No visible behavior or RPC payload changes.

### Implementation Record

Completed on 2026-08-04 against Task 01 commit `e6ab4fc`.

- Added Chat facade methods for immutable project identity, active permission
  state, session projection reset, current layout, process detail, and a
  detached display-state snapshot.
- Migrated Runtime and command callers away from Chat component fields. The
  architecture policy now has no Runtime/command Chat leak exceptions.
- Added an internal Runtime per-project record for display correlation,
  discovered commands, stats request de-duplication, direct Bash identity, and
  Client event unsubscription. Runtime no longer attaches these values to
  Client instances.
- Moved direct Bash/abort orchestration behind Runtime APIs and guarded callbacks
  by both project-record and Client identity, so an old Client cannot update a
  replacement Chat.
- Added `tests/lua/ui/chat/facade_spec.lua` and `tests/lua/runtime_spec.lua` for
  every Task 02 facade and lifecycle requirement. Expanded the architecture
  policy with failing dot- and bracket-field Client-state fixtures.
- `make test`, `make format-check`, `make smoke`, and
  `make ci-policy-check` passed after implementation. The smoke tests used the
  installed Pi 0.83.0 process without a model call.

## 9. Task 03: Decouple And Split The Chat Shell

### Goal

Keep `pi.ui.chat` as the stable UI facade while separating global registration,
window/layout lifecycle, and child-component behavior.

### Changes

1. Extract the global instance registry, resize/colorscheme/shutdown autocmds,
   and shared welcome animation into `pi.ui.chat.registry` or one equivalently
   cohesive module.
2. Extract main-window creation, position switching, window styling, responsive
   layout calculation, and close/reset behavior into `pi.ui.chat.shell`.
3. Keep component construction and public event delegation in `pi.ui.chat`.
4. Replace full-Chat constructor arguments in InputArea, CommandMenu,
   PermissionPanel, and WidgetArea with explicit dependency tables:
   - immutable values such as root and namespace;
   - state providers;
   - window/buffer providers; and
   - named actions such as render, layout, submit, close, or cancel.
5. Remove sibling reach-through such as CommandMenu reading InputArea fields or
   PermissionPanel reading TranscriptView fields.
6. Keep destroy operations idempotent and permission cancellation fail-closed.

Do not extract a generic event bus. Direct callbacks are clearer for the current
component count and match the existing TranscriptView construction pattern.

### Tests

Split broad Chat coverage by owner:

```text
tests/lua/ui/chat/facade_spec.lua
tests/lua/ui/chat/shell_spec.lua
tests/lua/ui/chat/activity_spec.lua
tests/lua/ui/chat/interaction_spec.lua
tests/lua/ui/chat/lifecycle_spec.lua
tests/lua/ui/input_spec.lua
tests/lua/ui/command_menu_spec.lua
tests/lua/ui/permission_spec.lua
tests/lua/ui/widget_spec.lua
```

Retain cross-component integration assertions, but do not repeat every component
algorithm in the facade spec.

### Exit Criteria

- Child components can be constructed in tests without a complete Chat object.
- No child component reads a sibling component field.
- `pi.ui.chat` exposes the same external behavior and owns composition only.
- Global timers and autocmds have one owner and deterministic teardown.

### Implementation Record

Completed on 2026-08-04 against Task 02 commit `02668b3`.

- Kept `pi.ui.chat` as the stable facade and composition root. Extracted the
  process-wide instance registry, UI autocmds, namespace, colorscheme refresh,
  and shared welcome animation into `pi.ui.chat.registry`.
- Extracted main-window creation, position changes, styling, responsive layout,
  and close/reset behavior into `pi.ui.chat.shell`. Shell is the sole mutable
  owner of the top-level window and layout fields.
- Replaced full-Chat constructor dependencies in InputArea, CommandMenu,
  PermissionPanel, and WidgetArea with explicit immutable values, providers,
  and named action tables. TranscriptView frontend actions are injected by
  Runtime through Chat, so UI modules no longer load the top-level `pi` facade.
- Removed every reviewed Lua require-cycle and sibling component-field
  exception. The architecture checker now has zero exception budgets and a
  failing policy fixture for UI-to-`pi` action dispatch.
- Split Chat coverage into facade, shell, activity, interaction, lifecycle, and
  registry specs. Added standalone InputArea and CommandMenu specs, plus
  standalone construction and idempotent teardown coverage for PermissionPanel
  and WidgetArea.
- `make test`, `make format-check`, `make smoke`, and `make ci-policy-check`
  passed after implementation. Smoke verification used the installed Pi 0.83.0
  process without a model call.

## 10. Task 04: Organize The Image Subsystem

### Goal

Give image source handling, preview generation, scheduling, backend placement,
and preview-window lifecycle separate owners behind `pi.ui.image`.

### Changes

1. Move source normalization, base64 decoding, private cache I/O, format-specific
   dimensions, pixel limits, and localization into `image/source.lua`.
2. Move RGBA half-block conversion and dynamic preview-highlight management into
   `image/preview.lua`.
3. Move preview task queue, debounce timers, concurrency limits, subprocess
   timeout, cancellation, and completion into `image/scheduler.lua`.
4. Group backend selection and adapters below `image/backend.lua` and
   `image/backends/`.
5. Move enlarged preview-window lifecycle below the image domain when doing so
   does not create a render-to-window dependency.
6. Keep `pi.ui.image` as the stable API used by Transcript and renderers.
7. Make ownership of cached files, timers, subprocesses, preview highlights, and
   `_pi_image` state explicit. Every release path must remain idempotent.

### Tests

Mirror the new owners with focused tests for source validation, dimensions,
cache behavior, preview conversion, scheduler concurrency/cancellation,
backend selection, placement lifecycle, and window teardown. Keep the existing
RPC image integration test as the end-to-end boundary.

### Exit Criteria

- Pure source and preview transformations can be tested without opening a
  Neovim window.
- Scheduler tests use controlled fake processes/timers and leave no live handle.
- Transcript and render modules depend only on the image facade.
- Existing image limits and fallback behavior remain unchanged.

## 11. Task 05: Organize Transcript Ownership

### Goal

Keep Transcript as one bounded display model while separating pure projection,
retention policy, history reconstruction, and buffer rendering.

### Changes

1. Extract bounded user, assistant, tool-argument, and tool-result transformations
   into `transcript/projection.lua`.
2. Extract candidate selection and release/accounting calculations into
   `transcript/retention.lua`. The Transcript object remains responsible for
   applying those decisions and emitting change notifications.
3. Extract history-to-display reconstruction into `transcript/history.lua`.
   History code must reuse the same projection rules as streaming events.
4. Move TranscriptView below the transcript domain, with a compatibility facade
   if its existing require path is treated as public.
5. Keep tool event correlation, live Bash materialization, item identity, and
   mutation ordering in the Transcript model unless extraction clearly reduces
   state coupling.
6. Prevent pure helpers from mutating authoritative RPC message tables.

### Tests

Add focused specs for projection, retention, history, model lifecycle, and view
render caching. Keep `regression/output_budget_spec.lua` for the cross-owner
memory ceiling and `integration/rpc_ui_spec.lua` for event ordering.

### Exit Criteria

- Streaming and history paths share projection behavior rather than duplicating
  it.
- Retention order is directly testable without rendering a buffer.
- Transcript remains the only owner of item IDs, tool correlation, and retained
  byte counters.
- TranscriptView owns buffers, render caches, ranges, and placements only.

## 12. Task 06: Split Security Policy Owners

### Goal

Keep authoritative security enforcement in bundled Extensions while giving each
policy a focused, testable module.

### Changes

1. Move shared path normalization, canonicalization, containment, and bounded
   file-header reading into focused helpers below `extensions/lib/security/`.
2. Move permission modes, approvals, prompt guidance, UI timeout handling, and
   tool-mode control into `security/permission.mjs`.
3. Move workspace read enforcement into `security/workspace.mjs`.
4. Move session-header parsing and same-root switch enforcement into
   `security/session-root.mjs`.
5. Keep `permission-gate.ts`, `workspace-guard.ts`, and
   `session-root-guard.ts` as thin Pi event-registration entries.
6. Avoid a new all-purpose `security/index.mjs` that simply recreates the current
   monolith.

### Tests

Move tests to mirror permission, path, workspace, and session-root owners. Every
security invariant must remain tested at the Extension layer; Lua presentation
tests cannot replace these tests.

### Exit Criteria

- Each Extension entry imports only its own policy and genuinely shared helpers.
- Unknown, malformed, cancelled, missing-UI, timeout, and thrown-error paths
  continue to fail closed.
- Plan-mode tool restrictions and restoration retain their exact tested
  behavior.
- `make smoke` proves the installed Pi process loads every bundled Extension.

## 13. Task 07: Align Test Structure And Focused Execution

### Goal

Make test discovery, file layout, and failure granularity follow production
ownership without weakening the complete suite.

### Changes

1. Implement one supported focused entry point:

   ```bash
   make test-file TEST=tests/lua/ui/chat/shell_spec.lua
   make test-file TEST=tests/extensions/security/permission.test.mjs
   ```

2. Make Lua and Extension test discovery recursive and deterministic.
3. Validate focused test paths, reject directories/globs/out-of-tree paths, and
   preserve runner failure as a non-zero Make result without trying another
   runner. GNU Make maps a failed recipe to its own documented non-zero status
   rather than returning an arbitrary child status unchanged.
4. Add an automated contract test for the focused runner.
5. Split broad specs according to Tasks 03 through 06; retain small facade and
   integration specs.
6. Create `tests/README.md` containing the ownership map, focused commands,
   complete gates, smoke boundary, and rules for choosing unit versus integration
   coverage.
7. Evaluate coverage tooling only as visibility. A percentage is not an
   architectural completion gate.

This task incorporates the still-relevant goals from
`docs/focused-test-command.md` and `docs/testing-improvements/`. Do not create a
second set of per-test migration plans.

### Exit Criteria

- Every production owner has a named primary test owner or an explicit reason it
  is covered at an integration boundary.
- A focused test failure identifies one behavior group.
- `make test` retains its current complete deterministic meaning.
- Test runner policy is itself covered.

## 14. Task 08: Documentation And Plan Closure

### Goal

Leave durable documentation that describes shipped behavior, not completed work
history.

### Changes

1. Update `docs/lua-architecture.md` with the final dependency graph, state
   ownership table, component contracts, and actual module tree.
2. Update the repository map in `AGENTS.md` when paths have changed.
3. Update `README.md` only where a user-visible command, requirement, or supported
   behavior changed.
4. Publish durable test workflow and ownership guidance in `tests/README.md`.
5. Remove `docs/testing-improvements/` and
   `docs/focused-test-command.md` after all implemented behavior is captured in
   tests, Make targets, and durable documentation.
6. Remove this plan after its completion record has been summarized in durable
   architecture documentation or release history.

### Exit Criteria

- No completed one-time task document remains in `docs/`.
- Every remaining design document clearly says whether it is shipped or
  proposed.
- Documentation paths and dependency claims match the repository exactly.

## 15. Verification Matrix

Run focused tests during each task, then run the complete gates before merging
that task:

```bash
make test
make format-check
make ci-policy-check
```

Run installed-process compatibility whenever Extension loading, RPC-facing Lua,
or deployment paths are affected:

```bash
make smoke
```

The final Task 08 verification requires all four commands. It also requires:

```bash
git status --short
rg -n 'chat\.(transcript|transcript_view|input_area|command_menu|permission_area|widget_area|image_backend|image_preview)' lua/pi
rg -n 'require.*pi\.ui\.' lua/pi/commands
```

The first command must show only intentional task changes before commit. The
second may match only the Chat composition implementation or documented private
compatibility code. The third must produce no command-layer dependency.

## 16. Delivery Rules

- Deliver one task at a time; do not combine the entire plan into one review.
- Preserve public facades before moving private implementation.
- Move tests with their production owner in the same task.
- Prefer mechanical moves followed by focused refactoring, so behavioral changes
  remain distinguishable from path changes.
- Do not mix visible UI redesign with architecture work.
- Do not weaken memory limits, fail-closed security behavior, event ordering, or
  lifecycle cleanup to simplify extraction.
- Stop and revise the target structure when an extraction introduces more
  bidirectional state sharing than it removes.

## 17. Risks

### Excessive Fragmentation

Small files are not automatically modular. Mitigate this by requiring every new
module to own a meaningful transformation, policy, or lifecycle and by retaining
stable facades.

### Lifecycle Regressions

Moving timers, autocmds, subprocesses, buffers, and windows can leak resources or
double-resolve callbacks. Require idempotent destroy tests and post-test handle
checks for every affected component.

### Performance Regressions

Additional facade calls and pure helper tables must not reintroduce full
transcript traversal during streaming. Keep the existing stable-prefix render
and retained-memory regression tests.

### Security Regressions

Splitting Extension policy can accidentally change exception handling or state
reset ordering. Preserve fail-closed tests at the authoritative Extension layer
before moving implementation.

### Compatibility Regressions

Private paths may still be used by tests or downstream configurations. Preserve
the explicitly stable facades, search the repository before each move, and add a
small compatibility module when a documented path must remain valid.

## 18. Final Definition Of Excellent

The project may be considered to have reached the target architecture when a
reviewer can answer all of these questions from paths, APIs, tests, and policy
checks without reading large implementation bodies:

- Where does each state value live?
- Which layer may change it?
- Which facade exposes it?
- Which focused test protects it?
- Which integration test protects its cross-layer behavior?
- Which automated rule prevents the dependency from reversing?
- Which cleanup path releases every resource it creates?

If any answer depends on reaching through another module's private fields, a
generic catch-all file, or an unimplemented planning document, the plan is not
complete.
