# Frontend Capability Gaps and Remediation Plan

## Status

This document records current, shipped limitations and confirmed edge-case defects in the native Neovim frontend. It is not a claim that the main workflow is unstable, and it is not a description of already implemented work.

Assessment baseline:

- pi.nvim current working-tree implementation.
- Pi Coding Agent `0.83.0` at `/home/hex4c59/.local/bin/pi`.
- Neovim `0.10` or newer, as required by the plugin.
- The ownership rules in the repository `AGENTS.md`.

Verification completed for this baseline:

```text
make test          passed
make format-check  passed
make smoke         passed against the installed Pi 0.83.0 process
```

The deterministic suite covers the JSONL parser, RPC client, fake RPC event ordering, runtime projection, renderer, layouts, dialogs, permission UI, image lifecycle, output budgets, bundled Extension policies, and repository policy checks. The smoke suite starts the installed Pi RPC process without calling a model and loads every bundled Extension.

No release-blocking failure was found in the normal prompt, streaming, tool, permission, model, thinking, queue, compaction, image, layout, or same-project session workflows. The gaps below concern completeness, long-session scaling, and several edge cases.

## Priority Summary

| Priority | Gap | Primary owner | Current consequence |
| --- | --- | --- | --- |
| P1 | Full-history RPC responses have a fixed 10 MiB frame ceiling | Pi RPC and pi.nvim client | A sufficiently large persisted session cannot be loaded reliably |
| P2 | Authentication and several administrative workflows are TUI-only | Pi RPC, then pi.nvim UI | Users must leave Neovim for login/logout, reload, trust changes, and related commands |

Priority describes remediation order and user impact, not security severity. The permission gate, workspace guard, and session-root guard remain authoritative in bundled Pi Extensions.

## 1. Large Session History Is Not Incrementally Loadable

### Classification

- Priority: P1
- Status: confirmed architectural limit
- User-visible area: startup, resume, new-session reload, long-running persisted sessions
- Authoritative owner: Pi session storage and Pi RPC
- Presentation owner: pi.nvim history projection and local retention budgets

### Current behavior

`Client.new()` creates the JSONL parser without overriding its frame limit:

```lua
self.parser = Parser.new({
  on_message = function(message, frame_bytes)
    self:_enqueue_dispatch("message", message, nil, frame_bytes)
  end,
  -- ...
})
```

`Parser.new()` defaults `max_frame_bytes` to 10 MiB:

```lua
max_frame_bytes = opts.max_frame_bytes or (10 * 1024 * 1024)
```

After `get_state` succeeds, client startup issues one `get_messages` request. Pi 0.83 responds with the complete `AgentMessage[]` in one JSONL record. `runtime.reload_session()` uses the same complete-history request after switching, forking, cloning, or creating a session.

The relevant frontend files are:

- `lua/pi/protocol.lua`
- `lua/pi/client.lua`
- `lua/pi/runtime.lua`

The relevant Pi 0.83 contract is `get_messages` in:

- `packages/coding-agent/src/modes/rpc/rpc-types.ts`
- `packages/coding-agent/src/modes/rpc/rpc-mode.ts`
- `packages/coding-agent/docs/rpc.md`

### Why the local transcript budget does not solve it

`output.transcript_max_bytes` controls retained Lua bodies after RPC data has been decoded and projected into chat items. It protects steady-state Neovim rendering and retained transcript memory, but it does not constrain:

1. The JSON object Pi constructs for `get_messages`.
2. The size of the JSONL record crossing stdout.
3. The temporary allocation made by `vim.json.decode`.
4. The complete decoded `messages` table delivered to `render_history()`.

Therefore, increasing or decreasing `transcript_max_bytes` does not make large-session loading incremental.

The dispatch queue budget also does not solve this bootstrap problem. It limits decoded records waiting for scheduled dispatch, while `get_messages` is one potentially large record.

### Failure mode

When the serialized response exceeds 10 MiB:

1. `Parser:_append()` emits `RPC frame exceeded maximum size`.
2. The parser discards bytes until the next LF so it does not interpret the tail as a new record.
3. The `get_messages` response never reaches `Client:_handle()`.
4. The pending request remains until the normal request timeout.
5. The history callback ignores unsuccessful responses, so the parser error is visible but there is no dedicated “history could not be loaded” state in the chat.
6. The client can otherwise appear connected and idle, leaving a partial user experience: current state is available, but persisted history is missing.

This is deterministic from the protocol and client implementation even though the smoke fixture uses a small session.

### Why simply increasing 10 MiB is insufficient

Making the fixed frame limit larger postpones the failure but preserves all of the underlying problems:

- Startup latency grows with the complete session.
- Peak memory remains proportional to all persisted messages.
- One malformed or unexpectedly huge response can block Neovim longer during JSON decoding.
- The frontend still discards most old bodies after paying the full transport and decode cost.
- There is no stable upper bound for a long-lived session containing many tool results.

A configurable larger frame limit can be useful as a compatibility escape hatch, but it is not the primary fix.

### Required backend capability

Pi RPC should provide bounded history pagination. The contract must preserve authoritative session ordering and identify a stable continuation point.

One possible request shape is:

```json
{
  "id": "nvim-12",
  "type": "get_messages_page",
  "before": "entry-or-message-cursor",
  "limit": 100,
  "maxBytes": 1048576
}
```

One possible response shape is:

```json
{
  "id": "nvim-12",
  "type": "response",
  "command": "get_messages_page",
  "success": true,
  "data": {
    "messages": [],
    "oldestCursor": "cursor-value",
    "hasMore": true,
    "leafId": "active-session-leaf"
  }
}
```

The exact cursor should be selected by Pi core. pi.nvim must not infer ordering or branch identity from rendered timestamps or local array offsets.

The backend design must define:

- Whether pages are ordered oldest-to-newest or newest-to-oldest.
- Whether the cursor identifies a session entry or a projected agent message.
- Behavior when compaction entries and branch summaries alter the active context.
- Snapshot consistency if a page request overlaps an active agent turn.
- A server-enforced item and byte cap.
- Whether tool results are returned in full, server-truncated, or represented by a structured omission record.
- How callers detect that the active leaf changed between page requests.
- Compatibility behavior for clients that only know `get_messages`.

`get_entries` with only a `since` cursor does not by itself solve initial history bootstrap because a new client does not know a cursor near the active leaf and cannot request a bounded page backwards.

### Required frontend changes

After a paginated RPC exists, pi.nvim should:

1. Load the newest bounded page first.
2. Render the current conversation tail immediately.
3. Keep a server-provided history cursor in client/session adapter state.
4. Fetch older pages on an explicit history action or when the user scrolls near the oldest loaded item.
5. Apply `transcript_max_bytes` while merging each page, not after accumulating all pages.
6. Preserve the user's cursor and scroll position while prepending older items.
7. Reject stale page responses after a session switch or process generation change.
8. Show a structured “older history not loaded” row when more pages exist.
9. Show a retryable error row when a history page fails.
10. Keep Pi's session as the only authoritative history source.

The renderer must not parse a visual omission row to recover pagination state. The Chat or runtime layer should retain a structured cursor and `has_more` flag.

### Test requirements

Pi repository:

- RPC type tests for request and response validation.
- Pagination ordering tests over messages, tool results, compaction entries, and branches.
- Byte-cap tests using multibyte content.
- Snapshot or stale-cursor behavior tests.
- Documentation examples in `docs/rpc.md`.

pi.nvim repository:

- Fake RPC fixture with at least three pages and a stale-page response.
- Client test proving no history frame exceeds the configured page budget.
- Runtime test for prepend ordering and duplicate suppression.
- UI test preserving cursor/scroll position while older history is inserted.
- Output-budget regression test proving retained bodies stay bounded across many pages.
- Error-state and retry test.
- Installed-process smoke that requests a page without calling a model.

### Acceptance criteria

- A session whose serialized history is substantially larger than 10 MiB opens successfully.
- The newest conversation page becomes usable without decoding the complete session.
- Loading additional pages does not violate `transcript_max_bytes`.
- Session switches cannot merge pages from different sessions.
- The old `get_messages` RPC remains compatible for older clients or is removed only with an explicit minimum-version change.

## 2. Administrative Pi Workflows Still Require the TUI

### Classification

- Priority: P2
- Status: explicit compatibility limitation
- User-visible area: slash-command catalogue and setup/maintenance workflows
- Primary owner: Pi core and RPC
- Frontend owner after protocol support: command adapter and native picker/dialog presentation

### Current unavailable commands

`lua/pi/runtime.lua` deliberately reports precise Pi 0.83 limitations for:

| Command | Current limitation |
| --- | --- |
| `/login` | Provider authentication is not exposed by RPC |
| `/logout` | Credential removal is not exposed by RPC |
| `/trust` | Trust cannot be changed inside the active RPC process |
| `/reload` | Extensions, skills, prompts, and other resources cannot be reloaded through RPC |
| `/scoped-models` | Model cycling scope cannot be changed through RPC |
| `/import` | External JSONL import is not exposed by RPC |
| `/share` | Secret gist/session sharing is not exposed by RPC |
| `/changelog` | The changelog view is not exposed by RPC |

These commands remain searchable in completion and are labelled as TUI-only. They are not sent blindly as model prompts. That behavior is correct and must remain the fallback for unsupported Pi versions.

### Capability grouping and ownership

Authentication:

- Pi owns provider discovery, credential storage, OAuth/API-key flows, validation, and logout.
- Lua may render structured prompts and status, but must not implement provider authentication independently.
- Secret input must use a protocol field that marks it as sensitive so the client can disable history, echo, logs, and transcript insertion.

Project trust:

- Pi owns trust semantics and protected resource loading.
- Changing trust may require a resource reload or process restart.
- pi.nvim must not claim that trust changes tool permissions; bundled security modes are separate.

Resource reload:

- Pi owns Extension, skill, prompt-template, package, context, and theme loading.
- An RPC reload must report which resources changed and whether the active session/Extension context was rebound.
- pi.nvim must clear or refresh command catalogues and Extension-owned UI state after authoritative completion.

Import/share/changelog/scoped models:

- Import is session-manager behavior.
- Share owns network/GitHub behavior and authentication in Pi.
- Changelog data belongs to the installed Pi version.
- Scoped model configuration belongs to Pi settings and model cycling.

### Recommended protocol approach

Do not add one generic `run_tui_command` RPC. That would expose prose-oriented terminal workflows and force the Neovim client to scrape or emulate TUI state.

Add structured commands only where a custom UI can safely implement the workflow. Examples:

```json
{"type":"get_auth_providers"}
{"type":"begin_auth","provider":"anthropic","method":"api-key"}
{"type":"submit_auth_value","flowId":"...","value":"..."}
{"type":"logout_provider","provider":"anthropic"}
{"type":"get_project_trust"}
{"type":"set_project_trust","decision":"trusted"}
{"type":"reload_resources"}
{"type":"get_model_scope"}
{"type":"set_model_scope","models":[{"provider":"...","id":"..."}]}
```

Authentication likely needs an event-driven flow rather than a single request because providers can require browser login, device codes, multiple prompts, or callback waiting. The RPC types must identify sensitive values structurally; the client must not infer sensitivity from labels such as “API key”.

### Frontend requirements

- Build native selectors for structured choices.
- Use concealed scratch input for secrets and never add secret content to transcript/history.
- Report browser/device-code steps without pretending Neovim completed them.
- Refresh `get_state`, available models, and command catalogue after auth/reload changes.
- Preserve the current Pi process/session only if the backend contract guarantees safe rebinding.
- Otherwise perform an explicit controlled restart and explain the state transition.
- Keep precise unsupported messages behind an explicit Pi version/capability gate.

### Test requirements

- Protocol tests must use fake credentials and no paid model calls.
- Redaction tests must assert secrets never reach logs, notifications, buffers, test snapshots, or process arguments.
- Reload tests must verify command catalogue and Extension status replacement.
- Trust tests must keep trust separate from tool permission modes.
- Installed smoke should validate command availability and a non-secret no-op path only.

### Acceptance criteria

- Supported administrative workflows can complete without launching Pi's TUI.
- No TUI screen parsing or key simulation is introduced.
- Authentication secrets remain outside transcripts and logs.
- Unsupported providers/workflows return structured errors and leave existing state unchanged.

## Intentional Limitations That Must Not Be Misclassified

The following behaviors are deliberate and should not be “fixed” solely in Lua:

### Cross-project resume remains blocked

Pi 0.83 does not provide enough authoritative state to migrate a project-bound Neovim client safely. Both Lua preflight and the bundled `session-root-guard.ts` enforce the current rule. Removing only the Lua check would not make switching safe.

### Transcript truncation does not modify Pi's session

`transcript_max_bytes` bounds the local Neovim projection. It must never be described as compaction or session deletion. Pi remains authoritative for messages and context construction.

### Permission prompts have no implicit timeout

The bundled permission gate intentionally waits for a decision and fails closed when UI is unavailable or cancelled. Generic Extension timeout support must not add a timeout to permission decisions that did not request one.

### `auto` permission mode is not a sandbox

It allows structurally valid model tools to use the host permissions of the Pi/Neovim process. Bundled guards are trusted in-process policy, not OS isolation.

### Remote and escaping image targets remain text

The frontend intentionally does not fetch remote Markdown images or paths escaping the canonical workspace. This protects the editor from model-triggered network fetches and arbitrary local file disclosure. Terminal/text fallback is expected behavior, not a missing image feature.

### TUI-only custom component APIs cannot be rendered directly

Pi Extension APIs such as `ctx.ui.custom()`, component factories, custom headers/footers, and TUI theme components do not have equivalent structured payloads in Pi 0.83 RPC. pi.nvim must not parse or embed Pi's terminal screen to simulate them.

## Recommended Delivery Sequence

The sequence below respects ownership and minimizes frontend compatibility branches.

### Phase 1: paginated history

1. Define cursor, snapshot, ordering, and byte-budget semantics in Pi.
2. Implement bounded history pages and compatibility behavior.
3. Add large deterministic Pi fixtures.
4. Build and install Pi.
5. Replace complete `get_messages` bootstrap with newest-page-first loading.
6. Add prepend/scroll/output-budget/stale-session tests.
7. Verify a session larger than the old 10 MiB ceiling against the installed process.

Large history is the next delivery phase because it is the highest-impact remaining architectural gap and has the broadest protocol and renderer implications.

## Required Verification Matrix

Every completed phase should run the tests owned by the changed layer.

### Pi backend changes

```bash
cd /home/hex4c59/Code/Typescript/pi
npm run check
```

Run the focused tests prescribed by the Pi repository and then its deterministic test command. Do not call paid model APIs.

For a complete local build and tarball set:

```bash
npm run release:local -- \
  --out /tmp/pi-local-release \
  --force \
  --skip-install
```

Install all generated workspace tarballs, not only `pi-coding-agent`, so local internal-package changes are preserved:

```bash
npm install -g --ignore-scripts /tmp/pi-local-release/tarballs/*.tgz
hash -r
pi --version
readlink -f "$(command -v pi)"
```

The expected executable on this system is `/home/hex4c59/.local/bin/pi`.

### pi.nvim changes

```bash
cd /home/hex4c59/Code/Lua/pi.nvim
make test
make format-check
make smoke
```

When protocol event ordering changes, update all of:

- `lua/pi/client.lua`
- `lua/pi/runtime.lua`
- `tests/fixtures/fake_pi.js`
- focused Lua client/runtime/UI tests
- smoke tests when the capability is verifiable without a model
- README capability and limitation text

### Manual verification

Automated headless tests should be supplemented with manual checks for:

- Right, bottom, tab, and float layouts.
- Small and normal terminal dimensions.
- A long persisted session.
- Session switching while the Chat is open and closed.
- Pi process restart after changing the installed package.
- Kitty/Ghostty terminal image backend and text/block fallback where available.

Manual verification does not replace deterministic tests for protocol or policy behavior.

## Definition of Done

A capability gap in this document is complete only when all applicable conditions hold:

- There is exactly one authoritative owner for every new state field.
- Pi-owned behavior is implemented in Pi core/RPC rather than reconstructed in Lua.
- Extension workflow/security decisions remain inside Pi Extensions.
- Lua only owns Neovim input, presentation, local context, and bounded projection state.
- RPC types, implementation, client types, tests, and docs agree.
- Older unsupported Pi versions receive an explicit capability message or the minimum version is raised.
- No client mirror is updated before authoritative success.
- Session and process generation races are covered.
- Security-sensitive failures remain fail-closed.
- `make test`, `make format-check`, and `make smoke` pass.
- README describes only behavior that is actually shipped.
- This document is updated to remove completed limitations rather than continuing to describe fixed behavior as outstanding.
