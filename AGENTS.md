# pi.nvim Development Guide

## Purpose

This repository is a native Neovim frontend for Pi Coding Agent. It is not a
fork of Pi, an alternative agent runtime, or a terminal wrapper around Pi's TUI.

The most important development rule is to preserve ownership boundaries between:

1. Pi core and its RPC server.
2. Bundled Pi Extensions in `extensions/`.
3. The pi.nvim RPC client and native Neovim UI in `lua/pi/`.

Do not implement a feature in Lua merely because the native Neovim UI needs to
expose it. First identify which layer must own the behavior and state.

## Official Pi Model

Pi describes itself as a minimal, extensible agent harness. Pi core provides the
agent loop and primitives; workflows that other agents may hard-code are often
intended to be Extensions.

Official Pi explicitly does not provide built-in permission popups, plan mode,
sub-agents, or a sandbox. Permission gates, path protection, plan mode, custom
tools, commands, workflow state, and policy interception are documented
Extension use cases.

Pi supports four integration modes:

| Mode | Purpose |
| --- | --- |
| Interactive/TUI | Pi's own terminal frontend |
| Print/JSON | Non-interactive output and event streams |
| RPC | JSONL subprocess integration for IDEs and custom UIs |
| SDK | Direct embedding in Node.js/TypeScript applications |

pi.nvim uses RPC because it is a Lua/Neovim custom UI. It starts one
`pi --mode rpc` subprocess per project. Do not parse, embed, or automate Pi's TUI
screen.

## Sources Of Truth

This repository currently targets Pi Coding Agent 0.83.0. Official `latest`
documentation may describe APIs that are newer than the installed process.

Before changing RPC or Extension behavior, check sources in this order:

1. Run `pi --version` for the executable that pi.nvim will launch.
2. Read the matching installed package documentation and type declarations.
3. Inspect the matching Pi source implementation when documentation is
   ambiguous.
4. Read current official documentation for intended architecture and newer
   capabilities.
5. Treat existing pi.nvim behavior and tests as compatibility requirements, not
   proof of Pi semantics.

Useful local paths for a global npm installation:

```text
$(npm root -g)/@earendil-works/pi-coding-agent/docs/rpc.md
$(npm root -g)/@earendil-works/pi-coding-agent/docs/extensions.md
$(npm root -g)/@earendil-works/pi-coding-agent/docs/security.md
$(npm root -g)/@earendil-works/pi-coding-agent/dist/modes/rpc/rpc-types.d.ts
$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
$(npm root -g)/@earendil-works/pi-coding-agent/examples/extensions/
```

Official references:

- https://pi.dev/docs/latest
- https://pi.dev/docs/latest/rpc
- https://pi.dev/docs/latest/extensions
- https://pi.dev/docs/latest/security
- https://github.com/earendil-works/pi/tree/main/packages/coding-agent
- https://github.com/earendil-works/pi/tree/main/packages/coding-agent/examples/extensions

When behavior differs across versions, implement against the configured minimum
version or raise the minimum explicitly. Do not silently depend on a newer Pi.

## Local Pi Source And Deployment

A writable Pi monorepo checkout is available locally:

```text
/home/hex4c59/Code/Typescript/pi
```

Its Git remotes are:

```text
origin    https://github.com/Hex4C59/pi.git
upstream  https://github.com/earendil-works/pi.git
```

Use this checkout when pi.nvim needs a Pi core, RPC, SDK, provider, agent,
session, or other upstream-owned change. Unless the user explicitly asks to stop
at a patch or design, carry such work through source edits, Pi tests, local
packaging, user-level installation, and installed-process smoke verification in
the same task. Do not patch the generated files under
`$(npm root -g)/@earendil-works/pi-coding-agent/dist`; global npm installs are
deployment artifacts and will be replaced on the next install.

Before editing Pi:

1. Read `/home/hex4c59/Code/Typescript/pi/AGENTS.md` and the relevant package
   documentation.
2. Check both repositories for uncommitted work and preserve changes from other
   sessions.
3. Fetch `upstream` and update the Pi branch only with a safe fast-forward, or
   create a feature branch when local commits are required. Never discard or
   rewrite unrelated work.
4. Make the authoritative change in the owning Pi package. RPC protocol changes
   normally touch `packages/coding-agent/src/modes/rpc/rpc-types.ts`,
   `rpc-mode.ts`, `rpc-client.ts`, matching tests, and `docs/rpc.md`.
5. Update pi.nvim's Lua adapter, fake RPC fixture, tests, minimum-version or
   capability gates, and user-facing documentation in the same feature.

For development, run Pi directly from the checkout when that is sufficient:

```bash
cd /home/hex4c59/Code/Typescript/pi
npm install --ignore-scripts  # first setup, or after dependency/lockfile changes
./pi-test.sh --version
./pi-test.sh --mode rpc
```

Follow the Pi repository's own test rules before packaging. In particular, run
`npm run check` after code changes and use its prescribed focused tests or
`./test.sh`; do not call paid model APIs as part of deterministic verification.

To build and pack all local workspaces without requiring Bun, use Pi's local
release script in tarball-only mode. This preserves changes in internal packages
such as `pi-ai`, `pi-agent-core`, `pi-protocol`, and `pi-coding-agent` instead of
silently resolving them from the public npm registry:

```bash
cd /home/hex4c59/Code/Typescript/pi
npm run release:local -- \
  --out /tmp/pi-local-release \
  --force \
  --skip-install
```

The release script regenerates model data, runs checks and tests, builds every
publishable workspace, and writes npm tarballs under
`/tmp/pi-local-release/tarballs/`. Do not add `--skip-check` or `--skip-test`
unless the user explicitly accepts the reduced verification.

Install the complete local package set into the current user-level npm prefix:

```bash
npm install -g --ignore-scripts /tmp/pi-local-release/tarballs/*.tgz
hash -r
pi --version
readlink -f "$(command -v pi)"
```

The expected npm prefix on this system is `/home/hex4c59/.local`, with the Pi
entry point at `/home/hex4c59/.local/bin/pi`. Verify that the resolved executable
is under that prefix and that the installed RPC behavior, not only the version
string, includes the new capability. After replacement, stop existing pi.nvim
clients with `:PiStop` or restart Neovim so new RPC subprocesses load the new
installation. Finally run pi.nvim's `make smoke` plus the focused Lua tests for
the added protocol behavior.

Keep Pi core changes in the Pi repository and pi.nvim frontend changes in this
repository. Do not copy Pi source or generated `dist` files into pi.nvim.

## Ownership Boundaries

### Pi Core Owns

Pi core is authoritative for:

- Model providers, authentication, API requests, retries, and model catalogues.
- The agent loop, turns, message generation, thinking, and tool-call scheduling.
- Built-in tool definitions and actual tool execution.
- Session files, session trees, messages, branching, forking, and cloning.
- Compaction, context construction, token/cost accounting, and queue semantics.
- Extension, skill, prompt-template, theme, and package loading.
- Project trust and Pi configuration semantics.
- RPC command, response, event, and Extension UI protocol definitions.

pi.nvim may invoke these capabilities through documented RPC commands and render
their results. It must not become a second authoritative implementation.

Examples:

| Feature | Correct owner |
| --- | --- |
| Model login/logout | Pi core/TUI; pi.nvim only reports RPC limitations |
| Model selection | Pi core state via RPC; Neovim supplies the picker UI |
| Session persistence | Pi core |
| Compaction algorithm and summaries | Pi core or a Pi Extension |
| Tool execution | Pi core or a Pi Extension custom tool |
| Steering/follow-up delivery | Pi core; pi.nvim submits the requested behavior |
| Session token/cost totals | Pi core; pi.nvim displays reported values |

### Bundled Pi Extensions Own

Extensions own behavior that changes the harness, tool policy, or agent workflow
without modifying Pi core. Code belongs under `extensions/` when it must run
inside Pi or must observe authoritative Pi lifecycle/tool events.

Use an Extension for:

- Blocking or mutating a tool call before execution through `tool_call`.
- Permission policy and session-scoped approvals.
- Workspace/path protection at the execution boundary.
- Plan mode or other changes to active tools and agent workflow.
- Custom LLM-callable tools.
- Custom slash commands whose state belongs to Pi/the session.
- Dynamic context injection or message filtering.
- Custom compaction behavior.
- State that must follow Pi session branching or restoration.
- Authoritative session lifecycle guards.

The files in `extensions/` are Pi Extensions, not Neovim plugins. They are loaded
with Pi's `--extension` CLI option by `lua/pi/config.lua`.

An Extension runs with the same host permissions as Pi and Neovim. It is a
guardrail and trusted code, not an OS sandbox.

Examples:

| Feature | Correct owner |
| --- | --- |
| Permission allow/block decision | Bundled Pi Extension |
| Permission mode and session approvals | Bundled Pi Extension |
| Permission dialog rendering | pi.nvim |
| Read-only workspace enforcement | Bundled Pi Extension |
| Same-root session switch final guard | Bundled Pi Extension |
| Friendly preflight error before an RPC request | pi.nvim, only as defense in depth |
| Plan mode tool restrictions | Bundled Pi Extension |

### pi.nvim Lua Owns

Lua owns the RPC transport adapter and native Neovim frontend:

- Starting, stopping, and tracking one Pi RPC subprocess per project.
- Strict LF-delimited JSONL framing and request/response correlation.
- Translating RPC events into local display state.
- Neovim buffers, windows, floating overlays, Extmarks, highlights, keymaps, and
  responsive layout.
- Transcript rendering, local folding/expansion, scroll behavior, and image
  placement.
- Prompt editing, command completion UI, pickers, and dialog presentation.
- Gathering Neovim-only context such as unsaved buffer text, visual selections,
  diagnostics, quickfix entries, marks, and visible ranges.
- Client-side output and memory budgets needed to keep Neovim responsive.
- Display-only mirrors of authoritative Pi or Extension state.
- Clear user-facing errors for capabilities absent from the supported RPC
  version.

Lua may validate an operation early for better UX, but client validation must
not be the only enforcement for a security or workflow invariant that Pi can
execute independently.

Examples:

| Feature | Correct owner |
| --- | --- |
| Markdown and tool timeline rendering | pi.nvim |
| Permission panel layout and keyboard navigation | pi.nvim |
| Returning a user's permission selection | pi.nvim |
| Deciding whether the tool is allowed | Pi Extension |
| Collecting unsaved current-buffer content | pi.nvim |
| Sending a prompt with image blocks | pi.nvim transport; Pi owns model handling |
| Rendering images in a Neovim window | pi.nvim |
| Local transcript truncation | pi.nvim; never claim it changes Pi's session |

## Decision Procedure For New Features

Before coding, answer these questions in order:

1. Is this model, session, tool, provider, queue, or compaction behavior already
   owned by Pi core?
2. Is the capability exposed by the supported RPC version?
3. Does the behavior need an authoritative Pi event such as `tool_call`,
   `session_start`, `context`, or `session_before_switch`?
4. Is it only presentation or Neovim-specific context?

Use this result:

| Answer | Action |
| --- | --- |
| Pi owns it and RPC exposes it | Call RPC and render the result |
| Pi owns it but RPC does not expose it | Report the limitation or propose an upstream RPC change |
| It customizes harness behavior | Implement a bundled Pi Extension |
| It is Neovim presentation/input/context | Implement in Lua |
| It spans Extension and UI | Extension owns state/decision; Lua displays and returns input |

Do not work around a missing RPC capability by scraping the TUI, reading terminal
screen contents, simulating TUI keys, or inventing local authoritative state.

Do not duplicate Pi behavior to make the native UI appear feature-complete. A
clear unsupported message is better than a misleading partial implementation.

## RPC Rules

The RPC protocol is a JSONL protocol over stdin/stdout, not JSON-RPC and not a
terminal protocol.

- Split records only on LF (`\n`).
- Strip an optional trailing CR from a frame.
- U+2028 and U+2029 are valid inside JSON strings and are not delimiters.
- Add request IDs and correlate responses through `Client.pending`.
- Commands may respond before the resulting asynchronous event stream ends.
- `agent_end` is not always idle; retries, compaction, or queued work may follow.
- Use `agent_settled` when the UI needs the final idle transition.
- Correlate tool events by `toolCallId`.
- `tool_execution_update.partialResult` is accumulated output, not necessarily a
  delta; replace local display state unless the documented event is a delta.
- Direct RPC `bash_execution_update.delta` is a delta and uses the originating
  command ID.
- Extension commands are discovered by `get_commands` and invoked through the
  `prompt` command with `/name`.
- Built-in TUI-only commands are not returned by `get_commands` and must not be
  sent blindly as model prompts.

When adding protocol support:

1. Read the matching `docs/rpc.md` section.
2. Check matching `rpc-types.d.ts` or source.
3. Add parser/client tests.
4. Add an end-to-end fake RPC fixture when event ordering matters.
5. Add a real no-model smoke only when it verifies actual Pi compatibility.

## Extension UI Rules

In RPC mode, `ctx.mode` is `"rpc"` and `ctx.hasUI` is true because Pi forwards
Extension UI requests to the client.

Dialog methods block the Extension until pi.nvim responds:

- `select`
- `confirm`
- `input`
- `editor`

Fire-and-forget methods do not require a client response:

- `notify`
- `setStatus`
- `setWidget`
- `setTitle`
- `set_editor_text`

TUI-only Extension APIs such as `ctx.ui.custom()` are unavailable or degraded in
RPC mode. Do not attempt to render Pi TUI components inside Neovim. Implement a
native Neovim surface for the supported RPC payload, or request an upstream RPC
protocol extension when the payload lacks required structured data.

For any Extension dialog:

- Each request ID gets at most one response.
- Cancellation must return the protocol's cancelled/false value.
- Missing UI must fail closed for permission-sensitive operations.
- Client text is presentation, not an authoritative security payload.
- The Extension must validate every response before changing state or allowing
  execution.

## Permissions And Security

Pi has no built-in permission system or sandbox. Project trust controls loading
project-local resources; it does not constrain model tool access.

For this repository:

- `permission-gate.ts` must own permission decisions in confirm mode.
- `workspace-guard.ts` must own read-only workspace enforcement.
- `session-root-guard.ts` must own the final same-root switch invariant.
- `lua/pi/ui/permission.lua` may own only the Neovim permission surface.
- Lua must not infer tool kind from a dialog title or parse human-readable dialog
  text to make a security decision.
- Lua must not parse arbitrary shell strings and call them safe.
- Session approvals and permission mode state belong in the Extension if they
  affect tool execution.
- No UI, cancellation, timeout, thrown errors, malformed inputs, and unknown
  responses must block.

Read `docs/extension-owned-permissions.md` before refactoring permissions.

Never describe bundled guards as a sandbox. Recommend container, VM, micro-VM,
or another OS boundary for untrusted or unattended work.

## State Ownership

Every state value must have one authoritative owner.

| State | Owner |
| --- | --- |
| Current model and thinking level | Pi core |
| Session messages/tree/file/name | Pi core |
| Agent running/settled state | Pi events |
| Queue contents | Pi core/events |
| Permission mode and approvals | Permission Extension |
| Neovim window, cursor, folds, expanded tools | pi.nvim |
| Unsaved editor context | Neovim/pi.nvim |
| Rendered transcript lines | pi.nvim projection |

Display mirrors are allowed but must be clearly one-way. Do not update a mirror
optimistically if failure would make the UI disagree with the authoritative
owner. Wait for an RPC response/event or Extension status publication.

Extension state that must survive session restart or branching should follow
Pi's documented state-management pattern, typically session entries or tool
result `details`. Ephemeral approvals should not be persisted unless the product
explicitly requires it.

## Repository Map

```text
plugin/pi.lua                 Neovim command and autocmd registration
lua/pi/init.lua               Public Lua API and slash-command dispatch
lua/pi/config.lua             User options and Pi process argv construction
lua/pi/client.lua             Pi subprocess, RPC requests, responses, events
lua/pi/protocol.lua           Strict LF JSONL parser
lua/pi/runtime.lua            Per-project clients/chats and event projection
lua/pi/context.lua            Neovim buffer/selection/diagnostic context
lua/pi/message.lua            UI-independent Pi content-block text projection
lua/pi/format.lua             Shared compact display formatting
lua/pi/commands/              Native command adapters and selectors
lua/pi/commands/catalog.lua   Native slash-command metadata and merging
lua/pi/ui/chat.lua            Chat facade, top-level window, component layout
lua/pi/ui/transcript.lua      Bounded transcript display model
lua/pi/ui/transcript_view.lua Transcript buffer, render cache, ranges, images
lua/pi/ui/image_preview.lua   Temporary image preview buffer/window lifecycle
lua/pi/ui/render.lua          Stable rendering facade
lua/pi/ui/render/             Focused pure-ish transcript renderers
lua/pi/ui/input.lua           Prompt/status buffers, windows, and overlays
lua/pi/ui/command_menu.lua    Completion buffer/window and selection state
lua/pi/ui/widget.lua          Widget state, buffers, windows, and projection
lua/pi/ui/dialog.lua          Generic Extension UI protocol adapter
lua/pi/ui/permission.lua      Native permission presentation only
extensions/                   Bundled authoritative Pi Extensions
extensions/lib/              Testable Extension policy helpers
tests/fixtures/fake_pi.js     Deterministic RPC fixture
tests/lua/                    Headless Lua tests grouped by frontend area
tests/extensions/             Node tests grouped by Extension owner
tests/smoke/                  No-model tests against the installed Pi
tests/policy/                 Repository policy tests
```

Keep process transport, event projection, rendering, and command adapters
separate. Avoid placing unrelated responsibilities back into `lua/pi/init.lua`.

## Command Ownership

Slash commands fall into three categories:

| Category | Handling |
| --- | --- |
| RPC command exposed by Pi | Lua calls the documented RPC command |
| Bundled/custom Extension command | Send `/command args` through RPC `prompt` |
| Native frontend-only action | Handle in Lua, for example layout or local copy |

Before implementing a command locally, check `get_commands`, the supported RPC
commands, and whether it should be an Extension command.

Do not pretend that interactive TUI commands work in RPC mode. Authentication,
the full resume picker, changelog, trust UI, and other TUI-only surfaces must
either have documented RPC support or report a precise limitation.

## Extension Development

Bundled Extensions are TypeScript loaded directly by Pi through jiti. Keep the
entry file small and move reusable policy into `extensions/lib/` so it can be
tested without launching Pi.

- Use `ExtensionAPI` types from `@earendil-works/pi-coding-agent`.
- Inspect installed `.d.ts` files instead of guessing API fields.
- Use typed event guards when available.
- Start session-scoped timers/processes/watchers from `session_start` or on
  demand, not in the factory.
- Clean long-lived resources idempotently in `session_shutdown`.
- Use `tool_call` for pre-execution blocking or input mutation.
- Use `tool_result` for result transformation, not execution permission.
- Remember that sibling tools may execute in parallel after sequential
  preflight.
- Canonicalize paths at the Extension execution boundary.
- Keep unknown tools outside claimed policy coverage unless they register an
  explicit policy.
- Do not persist temporary permission grants accidentally through session
  entries.

Changes under `extensions/` require Node policy tests and, when API loading is
affected, the real Pi extension smoke test.

## Neovim UI Development

pi.nvim uses normal `nofile` buffers and Neovim windows, not a terminal buffer.

- Transcript text is a projection of Pi state, never the session source of
  truth.
- Keep renderer inputs structured; do not recover semantics by parsing rendered
  lines.
- Prefer Extmarks for semantic highlights and anchors.
- Keep the transcript read-only outside controlled render sections.
- Preserve user scroll position unless the user was following output.
- Coalesce streaming redraws.
- Bound retained client data before rendering; visual truncation alone does not
  bound memory.
- Treat optional UI integrations as optional and provide a text fallback.
- Never let a colorscheme, completion plugin, or user autocmd alter a
  permission-sensitive decision.

If Pi emits insufficient structure for a correct native UI, document the gap and
propose an RPC addition. Do not parse prose fields into security or session
semantics.

## Testing

The default tests must not call a model, require authentication, or use paid
tokens.

Run all deterministic tests:

```bash
make test
```

Run formatting checks:

```bash
make format-check
```

Run no-model compatibility smoke tests against the installed Pi:

```bash
make smoke
```

Run the GitHub Actions pinning policy:

```bash
make ci-policy-check
```

Test ownership follows implementation ownership:

| Change | Required tests |
| --- | --- |
| JSONL parser or Client | Lua protocol/client tests and fake RPC fixture |
| Event projection | Lua runtime/RPC UI tests |
| Renderer/UI | Headless Lua tests |
| Extension policy | `node:test` tests under `tests/extensions/` |
| Extension API usage/loading | `make smoke` |
| Security invariant | Authoritative Extension test plus client UI test |

For focused Lua tests, use the existing form:

```bash
nvim --headless -u tests/minimal_init.lua -l tests/lua/<area>/<name>_spec.lua
```

Do not weaken an authoritative Extension test and compensate with a Lua UI test.

## Version Changes

When upgrading Pi support:

1. Record the old and new `pi --version`.
2. Read the upstream changelog, RPC documentation, Extension documentation, and
   matching types/source.
3. Identify protocol additions, removals, semantic changes, and event ordering
   changes.
4. Update feature gates and user-facing RPC limitation messages.
5. Update fake RPC fixtures.
6. Run `make test`, `make smoke`, and `make format-check`.
7. Update README and architecture/security docs when ownership or guarantees
   change.

Do not add broad version-compatibility branches without a concrete supported
version matrix. Prefer one explicit minimum Pi version.

## Documentation Rules

- README documents shipped behavior, not plans.
- Design documents must state clearly when they are not implemented.
- Completed one-time task documents should be removed after durable behavior is
  captured in code, tests, README, or a current architecture document.
- Never cite Pi `latest` behavior as current 0.83 behavior without checking the
  installed package.

## Final Boundary Check

Before finishing any feature, verify:

- Is there exactly one authoritative owner for every new state value?
- Is agent/workflow policy in Pi or an Extension rather than Lua?
- Is Neovim-specific presentation/context in Lua rather than an Extension?
- Does pi.nvim use a documented RPC capability instead of reproducing Pi core?
- If RPC lacks a capability, is the limitation explicit instead of simulated?
- Are security decisions enforced before execution inside Pi?
- Do tests cover the authoritative layer and the UI adapter separately?
- Do README and docs describe what is actually shipped?
