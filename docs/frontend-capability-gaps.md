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
| P1 | Session listing and in-place tree navigation are absent from RPC | Pi RPC, then pi.nvim UI | `/resume` requires an exact path and the tree cannot activate an existing node |
| P2 | Authentication and several administrative workflows are TUI-only | Pi RPC, then pi.nvim UI | Users must leave Neovim for login/logout, reload, trust changes, and related commands |
| P2 | Auto-retry state and controls are incomplete | Pi RPC, then pi.nvim settings UI | Retry events render, but the current setting cannot be inspected or changed accurately |

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

## 2. Session Discovery and Tree Navigation Are Incomplete

### Classification

- Priority: P1
- Status: confirmed Pi 0.83 RPC capability gap
- User-visible area: `/resume`, `:PiTree`, `/tree`, branch navigation
- Authoritative owner: Pi session manager and RPC
- Presentation owner: pi.nvim picker and tree UI

### Current behavior

Pi 0.83 exposes:

- `switch_session` when the caller already knows a session path.
- `get_tree` for inspecting the current session tree.
- `get_fork_messages` and `fork` for creating a new branch from a user message.
- `clone` for duplicating the active branch.

Pi 0.83 does not expose:

- A session-list RPC command.
- An RPC command equivalent to in-place `navigate_tree`.
- Sufficient structured state for pi.nvim to migrate a project-bound client to a different canonical root safely.

Consequently:

- `/resume` prompts for an exact session JSONL path.
- pi.nvim reads only a bounded session header for same-root validation.
- `:PiTree` can inspect all nodes.
- Selecting a user-message node offers “Fork from this message” and “Copy message”.
- Selecting other nodes reports that the active leaf cannot be moved.
- Cross-project resume is rejected in every security mode.

Relevant frontend files:

- `lua/pi/commands/session.lua`
- `lua/pi/session_file.lua`
- `extensions/session-root-guard.ts`
- `extensions/lib/security/session-root.mjs`

### Why Lua must not implement a filesystem session index

Pi core owns session paths, formats, metadata, branches, compatibility, and future storage changes. A Lua implementation that recursively scans `~/.pi/agent/sessions`, parses filenames, and reconstructs display metadata would duplicate Pi session semantics and eventually diverge.

The existing bounded header read is intentionally narrower. It is defense in depth for a user-supplied path and supports the same-root preflight check; it is not a session catalogue.

### Required backend capability: session listing

Pi RPC should expose an authoritative, bounded session-list command. A possible request is:

```json
{
  "id": "nvim-20",
  "type": "list_sessions",
  "cwd": "/canonical/project/root",
  "limit": 100,
  "cursor": null
}
```

A possible response is:

```json
{
  "id": "nvim-20",
  "type": "response",
  "command": "list_sessions",
  "success": true,
  "data": {
    "sessions": [
      {
        "path": "/absolute/session.jsonl",
        "id": "session-id",
        "name": "Focused task",
        "cwd": "/canonical/project/root",
        "updatedAt": "2026-01-01T12:00:00.000Z",
        "messageCount": 42,
        "model": {
          "provider": "provider",
          "id": "model-id"
        }
      }
    ],
    "nextCursor": null
  }
}
```

The backend, not Lua, must define session discovery roots, malformed-session handling, sorting, canonical `cwd`, pagination, and metadata extraction.

The request may omit `cwd` and return all sessions if Pi wants the client to filter presentation only. For security-sensitive switching, the authoritative same-root guard must still run inside Pi immediately before the switch.

### Required backend capability: tree navigation

Pi RPC should expose the existing Pi core navigation behavior directly. A possible request is:

```json
{
  "id": "nvim-21",
  "type": "navigate_tree",
  "entryId": "target-entry-id",
  "summarize": true,
  "customInstructions": "optional summary guidance"
}
```

The response must distinguish success, user cancellation, and a stale/missing target:

```json
{
  "id": "nvim-21",
  "type": "response",
  "command": "navigate_tree",
  "success": true,
  "data": {
    "cancelled": false,
    "leafId": "new-active-leaf"
  }
}
```

Pi core must remain responsible for branch summaries, context rebuilding, session writes, and lifecycle events. Lua should only invoke the command and reload the resulting projection after authoritative success.

### Required frontend changes

Session picker:

1. Add a native session picker backed by `list_sessions`.
2. Default to the current canonical root.
3. Display session name, relative age/date, message count, and model without parsing session files locally.
4. Retain an explicit path entry route for advanced use and backward compatibility.
5. Wait for `switch_session` success before clearing or replacing the transcript.
6. Preserve current session UI if switching is cancelled or fails.

Tree UI:

1. Keep `get_tree` as the source of structure.
2. Add “Navigate to this node” only when the installed Pi advertises the RPC capability.
3. Submit the structured entry ID directly.
4. Show compaction/summary progress using Pi events.
5. Reload state, stats, messages/history cursor, permission mode, widgets, and title after success.
6. Prevent stale tree selections from acting after another session operation.

### Cross-project resume

Cross-project resume is currently an intentional safety limitation, not a missing Lua path check. A safe implementation requires an explicit lifecycle design for:

- Rebinding the client key from one canonical root to another.
- Deciding whether the old root keeps a separate Pi process and Chat.
- Rebinding current-buffer context collection.
- Revalidating project trust and context-file loading for the destination root.
- Reinitializing bundled guard roots inside Pi.
- Clearing session-scoped permission approvals.
- Rebinding image path resolution and cache ownership.
- Preventing old-root events from mutating the new-root UI.

Until Pi RPC returns enough authoritative destination state and the frontend can migrate these owners atomically, rejection is the correct behavior.

### Test requirements

Pi repository:

- Session listing over valid, malformed, renamed, and legacy sessions.
- Pagination and stable ordering.
- Tree navigation to ancestor, sibling branch, compaction, and summary nodes.
- Cancellation and stale entry ID behavior.
- Session lifecycle event ordering.

pi.nvim repository:

- Fake RPC list picker and pagination tests.
- Same-root and cross-root picker filtering/presentation tests.
- Tree navigation success, failure, and cancellation tests.
- Race test for two overlapping session actions.
- Permission mode and widget reset tests after a switch.
- Installed no-model smoke for list and navigation commands.

### Acceptance criteria

- `/resume` works without requiring users to locate a JSONL file manually.
- Tree nodes can be activated in place when Pi supports the command.
- No session operation updates the transcript optimistically.
- Same-root enforcement remains authoritative inside the bundled Extension.
- Older Pi versions receive a precise limitation message rather than an invalid RPC request.

## 3. Administrative Pi Workflows Still Require the TUI

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

## 4. Auto-Retry Is Rendered but Not Fully Controllable

### Classification

- Priority: P2
- Status: partial frontend support and Pi 0.83 state gap
- User-visible area: settings, retry activity, interruption
- Authoritative owner: Pi settings/session
- Presentation owner: pi.nvim

### Current behavior

Pi 0.83 RPC exposes:

- `set_auto_retry`
- `abort_retry`
- `auto_retry_start`
- `auto_retry_end`

pi.nvim handles retry events in `lua/pi/runtime.lua`:

- `auto_retry_start` changes the activity label to `retry attempt/maxAttempts`.
- Failed `auto_retry_end` adds the final error to the transcript.

The settings UI in `lua/pi/commands/ui.lua` exposes model, thinking, permission mode, auto-compaction, steering mode, follow-up mode, layout, and transcript detail. It does not expose auto-retry.

Pi 0.83 `get_state` does not include `autoRetryEnabled`, even though Pi core has an authoritative `autoRetryEnabled` getter. Without that state, a frontend toggle cannot reliably display the current value before changing it.

The generic `abort` RPC already calls `session.abort()`, and Pi core's `session.abort()` calls `abortRetry()` before aborting the agent. Therefore, the existing interrupt action can cancel retry sleep; the primary missing capability is accurate setting inspection and control, not basic cancellation.

### Required backend change

Add `autoRetryEnabled` to `RpcSessionState` and the `get_state` response:

```json
{
  "type": "response",
  "command": "get_state",
  "success": true,
  "data": {
    "autoRetryEnabled": true
  }
}
```

The real response will continue to include all existing state fields. This is an additive protocol change but still requires updating the targeted Pi version or a capability/version gate.

Optionally expose current retry state for reconnecting clients:

```json
{
  "isRetrying": true,
  "retryAttempt": 2
}
```

That addition would let a newly attached frontend reconstruct current activity without waiting for a future `auto_retry_start` event. It should be added only if Pi can guarantee consistent semantics with `isStreaming` and `agent_settled`.

### Required frontend changes

- Store `autoRetryEnabled` only from authoritative `get_state` data or successful RPC responses.
- Add an “Auto-retry” settings row.
- Send `set_auto_retry` with the inverse of the current authoritative value.
- Update the mirror only after success, or refresh state after success.
- Restore the previous display on failure.
- Include auto-retry in `/session` or `/settings`, not necessarily in the permanent footer.
- On versions without the state field, show `unknown` and either disable the toggle or offer explicit `enable`/`disable` commands rather than guessing.

### Test requirements

Pi repository:

- `get_state` reports the configured retry value.
- `set_auto_retry` changes the next `get_state` result.
- Retry state remains consistent across session switch/reload according to Pi settings semantics.

pi.nvim repository:

- Settings displays on/off/unknown correctly.
- Successful toggles update from authoritative state.
- Failed toggles do not change the local mirror.
- Fake retry event ordering keeps the activity label correct until `agent_settled`.
- Interrupt during retry sends an abort and returns to idle after Pi settles.
- Installed no-model smoke verifies the state and toggle commands without triggering a provider request.

### Acceptance criteria

- The settings surface shows the actual Pi auto-retry setting.
- Users can enable or disable it without entering the TUI.
- Reconnect/session changes cannot leave a stale optimistic value.
- Retry interruption remains consistent with Pi's authoritative settled event.

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

### Phase 1: retry state completeness

1. Add `autoRetryEnabled` to Pi RPC state.
2. Update Pi RPC types, mode implementation, client types, tests, and docs.
3. Build and install Pi.
4. Add the native settings control and frontend tests.
5. Verify the installed process reports and changes the setting without a model call.

### Phase 2: session discovery and navigation

1. Define authoritative session-list pagination in Pi core/RPC.
2. Expose in-place tree navigation through RPC.
3. Add Pi session/RPC tests and documentation.
4. Build and install Pi.
5. Implement the pi.nvim session picker and tree action.
6. Add same-root, cancellation, stale-response, and event-ordering tests.
7. Keep cross-project migration blocked until it has a separate lifecycle design.

### Phase 3: paginated history

1. Define cursor, snapshot, ordering, and byte-budget semantics in Pi.
2. Implement bounded history pages and compatibility behavior.
3. Add large deterministic Pi fixtures.
4. Build and install Pi.
5. Replace complete `get_messages` bootstrap with newest-page-first loading.
6. Add prepend/scroll/output-budget/stale-session tests.
7. Verify a session larger than the old 10 MiB ceiling against the installed process.

Although large history is the highest-impact architectural gap, it is listed last in delivery sequence because it has the broadest protocol and renderer implications. It should be designed first even if smaller correctness fixes ship earlier.

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
