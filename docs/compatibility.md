# Compatibility Contract

This document defines the compatibility promises made by pi.nvim. It records
the client behavior that must remain stable across refactors and the fallback
used when an installed Pi process does not advertise an optional RPC
capability. The matching Pi package RPC documentation, type declarations, and source
remain authoritative for the protocol schema itself.

The currently verified executable reports Pi Coding Agent `0.83.0`. That
version string alone is not a feature gate: this repository also targets Pi
changes that advertise their behavior through `get_state.rpcCapabilities`.
Clients must inspect capabilities instead of inferring them from the version.

## Supported Public Surface

### Neovim And Lua

The following surfaces are public compatibility commitments:

- `require("pi").setup(opts)` and the configuration keys documented in the
  README.
- The `:PiChat`, `:PiAsk`, `:PiVisual`, `:PiBuffer`, `:PiAbort`, `:PiModel`,
  `:PiThinking`, `:PiPermissions`, `:PiSettings`, `:PiLayout`, `:PiTree`,
  `:PiFork`, `:PiClone`, `:PiCommands`, `:PiNew`, `:PiCompact`, `:PiStatus`, and
  `:PiStop` commands, including their documented argument cardinality.
- Slash commands and user-visible keymaps documented in the README. Their Lua
  implementation owner may change without changing the user-facing behavior.
- The legacy `context.max_chars` configuration key, which remains an alias for
  `context.max_bytes` when `max_bytes` is not explicitly supplied.
- The `pi.ui.transcript_view`, `pi.ui.image_backend`,
  `pi.ui.image_backends.snacks`, and `pi.ui.image_preview` module paths. These
  are stateless aliases for their current owners and must not acquire separate
  state.

Other functions currently returned by `require("pi")` are command adapters for
the plugin's own entry points. They may be useful to mappings, but they are not
a stable programmatic API until documented here. Modules below `pi.client`,
`pi.runtime`, `pi.commands.*`, `pi.ui.chat.*`, `pi.ui.image.*`,
`pi.ui.render.*`, and `pi.ui.transcript.*` are internal owners, except for the
four compatibility aliases listed above.

### Process Launch Context

Every Pi process started by pi.nvim appends a fixed frontend identity with
`--append-system-prompt`. It tells the model that pi.nvim is the native Neovim
frontend and Pi Coding Agent is the backend agent runtime without replacing
Pi's default system prompt. It also tells the model not to assume Pi's terminal
UI or TUI-only controls are available. User-provided `extra_args` remain last
in the process argument list, so additional `--append-system-prompt` values
compose with the default identity.

Public commands, configuration keys, or module aliases must not disappear or
change meaning silently. A removal requires an explicitly declared breaking
release. Before that release, document the replacement in the README and this
file, retain a compatibility path where technically safe, and add a warning
when it does not expose secrets or disrupt headless use.

### State And Security

Compatibility never transfers authority from Pi or a bundled Extension to Lua.
Pi remains authoritative for model, session, queue, retry, compaction, and tool
state. Bundled Extensions remain authoritative for permission decisions,
workspace enforcement, and the same-root session invariant. A client fallback
may reduce available UI, but it must not simulate missing authoritative state or
weaken a security decision.

## RPC Capability Matrix

`get_state.rpcCapabilities` is the feature gate for optional commands and
events in this table. An absent or malformed list is treated as an empty list.
The retry setting also uses the typed `autoRetryEnabled` state field as a
structural compatibility probe, as described below. The required baseline is
different: a process missing a required event is not a supported pi.nvim
backend, even if startup happens to succeed.

| Capability or event | Status | pi.nvim behavior when available | Behavior when unavailable | Primary verification |
| --- | --- | --- | --- | --- |
| `extension_ui_cancel` | Required baseline capability/event | Close exactly the matching Extension dialog and reject any late client response | Permission-sensitive requests still fail closed, but the backend is unsupported because Pi-owned timeout/cancellation cannot be projected reliably | `tests/lua/ui/dialog_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `agent_settled` | Required baseline event | Mark the frontend idle only after retries, compaction retries, and queued continuations are complete | Do not reinterpret `agent_end` as a final idle event; the backend lacks the required lifecycle signal | `tests/lua/runtime_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua` |
| `auto_retry_state` and `get_state.autoRetryEnabled` | Optional capability/state | Read the authoritative boolean; change it with `set_auto_retry`; refresh state after success before updating the display mirror | If the field is absent, show `unknown` and require an explicit Enable or Disable selection instead of guessing current state; a rejected command leaves the mirror unchanged | `tests/lua/commands/ui_spec.lua`, `tests/smoke/client_smoke.lua`, `tests/smoke/extensions_smoke.mjs` |
| `list_sessions` | Optional capability | Request bounded, Pi-owned session catalogue pages with opaque cursors | Accept an exact session path; never scan or parse Pi's session store in Lua | `tests/lua/commands/session_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `navigate_tree` | Optional capability | Navigate by structured entry ID and refresh only after Pi confirms the new leaf | Allow tree inspection but report that navigation is unavailable; never simulate a branch change locally | `tests/lua/commands/session_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `history_pagination` | Optional capability | Use bounded `get_messages_page` responses, Pi-owned opaque cursors, and the active-leaf snapshot | Use the complete `get_messages` compatibility command; do not implement Pi context reconstruction in Lua | `tests/lua/runtime_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `administrative_workflows` | Optional capability | Use structured RPC for authentication, project trust, resource reload, model scope, import, sharing, and changelog workflows | Keep commands discoverable as unavailable/TUI-only and report a precise limitation; never send them as model prompts | `tests/lua/commands/admin_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua`, `tests/smoke/client_smoke.lua` |

Capability dependencies are explicit. Native session discovery needs
`list_sessions`; moving the active tree leaf independently needs
`navigate_tree`. Neither capability implies the other. Current Pi builds should
advertise `auto_retry_state`; pi.nvim also accepts a typed
`autoRetryEnabled` field from transitional builds and handles an unsupported
`set_auto_retry` response without changing its local mirror.

## Ordering And Failure Contract

- RPC records are LF-delimited JSONL. Responses are correlated by request ID;
  asynchronous events are not assumed to carry that ID.
- `output.rpc_queue_max_bytes` bounds each incoming and outgoing JSONL frame as
  well as the aggregate decoded dispatch queue. An oversized request is rejected
  before it reaches Pi; an oversized response frame fails before projection.
- A successful command response does not imply that its asynchronous workflow
  has settled. State mirrors update from the documented response or subsequent
  authoritative state/event, never optimistically.
- `agent_end` completes one low-level run. Only `agent_settled` represents the
  final idle transition.
- Extension dialog cancellation is Pi-owned. The client closes only the request
  named by `extension_ui_cancel` and cannot send a response after cancellation.
- History and session cursors are opaque. A malformed, stale, cross-session, or
  repeated cursor is an error, not an invitation to reconstruct server state.
- Missing capabilities, malformed responses, cancellation, timeout, and process
  replacement must leave the current authoritative projection unchanged or
  fail closed, according to the owning layer.

CI's `smoke-baseline` target starts the pinned public Pi package and loads every
bundled TypeScript Extension entry, but it is not a supported-backend claim and
does not replace `make smoke`. The complete smoke target runs against the
configured 0.83 capability build and verifies required dialog cancellation plus
optional capabilities present in that build.

## Changing The Contract

Any RPC command, response, event, public command, configuration key, or stable
module-path change must update this file in the same change. Protocol work must
also update the matching Pi source and documentation, fake RPC fixture, focused
Lua tests, and installed no-model smoke coverage. Record the observed
`pi --version`, but use a capability gate whenever independently deployable Pi
builds can differ while reporting the same version.

Reviewers should reject a compatibility branch that has no concrete supported
backend, no defined fallback, or no removal condition. README text describes
what users can do; this document defines which behavior a refactor or upgrade
must preserve.
