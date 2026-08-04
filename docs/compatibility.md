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
  `:PiFork`, `:PiClone`, `:PiNew`, `:PiCompact`, `:PiStatus`, and
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

The main prompt is a text-entry surface locked to Insert mode whenever its
window owns focus. `Esc` first clears attachment-token focus, then dismisses
completion, then interrupts active work. When Pi is idle or starting, `Esc`
instead leaves Insert mode and focuses the transcript canvas in Normal mode
without closing Chat or discarding the draft and attachments. Buffer-local
`Ctrl-Q` returns to the most recently used non-Pi editor window in Normal mode
without closing Chat, discarding the draft, or stopping the RPC process; an
invalid return window falls back to the Pi canvas in Normal mode. This contract
applies equally to right, bottom, tab, and float layouts. Permission prompts
retain their separate fail-closed `Ctrl-Q` cancellation behavior.

Pending prompt images use concealed buffer anchors projected as inline attachment
tokens. A single image is `[1 image attached]`; multiple images are separate
`[image N]` tokens. In Insert mode, `Right` immediately before a token focuses it
and places the real cursor after its anchor, so typing inserts text after that
image. Repeated `Right` advances through images; `Left` moves backward and
returns from the first token to the preceding text. With a token focused,
`Backspace` removes it and selects the previous token when present; `Delete`
removes it and prefers the next image at the same position, otherwise the new
last token. `Esc`, text edits, ordinary text movement, mouse positioning,
programmatic input replacement, submission, clear, close, and destruction
discard token focus.

Pi processes advertising `ordered_prompt_content` receive the exact visible
sequence as ordered text and image blocks. Older processes receive the legacy
`message` plus `images` shape only when all text precedes every image. If text
appears between or after images, pi.nvim rejects the lossy downgrade, restores
the full draft, and reports the missing capability. This is an additive RPC
capability; there is no public Lua API or configuration change.

Submitted user messages containing images are projected as a bounded ordered
list of copied text and localized image blocks. Rendering replaces each retained
user image with a sequential `[image N]` token while preserving the text/image
order. Each token has its own semantic highlight and exact byte-column hit
range: mouse clicks and Enter under the cursor open the existing image preview
only inside that range. User token descriptors remain available for interaction
but are excluded from terminal image backend synchronization. Assistant, tool,
and supported Markdown image descriptors retain their existing inline behavior.
Transcript clear, history replacement, budget release, and destruction release
the localized user image state.

Transcript code presentation uses a stable gutter with semantic extmarks.
Fenced Markdown code is numbered from one within each fence because it has no
authoritative file position; `diff` fences also use `+` and `-` symbols with
addition and deletion highlights. Expanded built-in `read` results use the
request's one-indexed `offset` (or one when absent) and stop numbering before
Pi's continuation or truncation notice. Expanded `write` previews number the
new file from one. Completed built-in `edit` results use Pi 0.83's
`result.details.diff` rows as the authoritative line numbers and change kinds.
While an edit is pending, or when those details are absent, pi.nvim may show the
submitted old/new text with `-` and `+` gutters but does not invent file line
numbers. This is display-only behavior and adds no RPC capability, configuration
key, or public Lua API.

Pi-owned selectors opened by slash commands or their `:PiModel`, `:PiThinking`,
`:PiPermissions`, `:PiSettings`, `:PiLayout`, `:PiTree`, `:PiFork`, and
`:PiClone` counterparts use one Chat-owned inline menu. The menu is a
borderless, full-width, canvas-relative candidate surface above the prompt with
a separate one-line query buffer/window over its `Filter:` or `Value:` row. It
is temporary UI and must not create transcript messages or authoritative state.
The query accepts Unicode text, IME composition, and paste through native Insert
mode; fuzzy matching and Backspace operate on characters rather than UTF-8
bytes. Arrows and `Ctrl-P`/`Ctrl-N` navigate, `Enter` submits, and `Tab` toggles
multi-selection. `Esc` pops one bounded submenu or closes the root, and
`Ctrl-Q` cancels the entire group before returning to the prior editor window.
Confirmation defaults to Cancel.

Opening an ordinary inline menu closes slash completion. A permission request
cancels the ordinary menu and remains fail-closed. Chat close/destruction,
session replacement, and process/client replacement invalidate menu callbacks
and release its window; focus restoration must not steal focus from a newer or
non-Chat surface. `Ctrl-L` and idle `Ctrl-P` prefill `/model `, `Alt-P` prefills
`/permissions `, and idle `Shift-Tab` prefills `/thinking `; slash completion
keeps priority for `Ctrl-P` and `Shift-Tab` navigation.

Ordinary administrative select, confirm, multi-select, and non-sensitive auth
input use the inline menu. RPC input marked `sensitive=true` remains isolated in
the concealed scratch buffer. Generic Extension dialogs, tool permission
requests, and image previews are not inline-menu surfaces.
On Pi processes without `list_sessions`, `/resume` prefills an exact-path slash
command; argument-less `/name` uses the same prompt-prefill pattern.

Transcript mouse state is display-only and generation-scoped. A left press in
the transcript records its owned buffer/window and byte position; a drag enters
Neovim character selection, and release copies exactly the visible selected
text to the `+` register. A release without a drag retains semantic tool,
process, and image clicks. Chat close/destruction, buffer invalidation, and
`WinClosed` invalidate the gesture before any stale callback can act. Right
click in the prompt focuses the clicked byte position and uses the existing
clipboard reader, attaching images or inserting text. pi.nvim does not change
global `mouse`, `mousemodel`, or `clipboard` options.

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

The command-surface cleanup is an intentional breaking change. `/mode`,
`/permission`, `/clear`, `/commands`, `/changelog`, `/export`, `/import`,
`/share`, `/abort`, `/llama`, and `/copy` are neither completed nor forwarded;
this also filters names returned dynamically by Pi. Manual entry reports that
the command is unsupported by pi.nvim. `:PiCommands` and the public Lua fields
`commands`, `copy_last_response`, `export_session`, `import_session`, `share`,
and `changelog` were removed. The lower-level `abort` Lua function, `:PiAbort`,
prompt `Esc`, and `Ctrl-C` remain supported cancellation paths.

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
| `list_sessions` | Optional capability | Request bounded, Pi-owned session catalogue pages with opaque cursors and append them to the inline session menu | Prefill `/resume ` for an exact session path; never scan or parse Pi's session store in Lua | `tests/lua/commands/session_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `navigate_tree` | Optional capability | Navigate by structured entry ID and refresh only after Pi confirms the new leaf | Allow tree inspection but report that navigation is unavailable; never simulate a branch change locally | `tests/lua/commands/session_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `history_pagination` | Optional capability | Use bounded `get_messages_page` responses, Pi-owned opaque cursors, and the active-leaf snapshot | Use the complete `get_messages` compatibility command; do not implement Pi context reconstruction in Lua | `tests/lua/runtime_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua`, `tests/smoke/extensions_smoke.mjs` |
| `administrative_workflows` | Optional capability | Use structured RPC for authentication, project trust, resource reload, and model scope workflows | Keep the remaining administrative commands discoverable as unavailable/TUI-only and report a precise limitation; never send them as model prompts | `tests/lua/commands/admin_spec.lua`, `tests/lua/integration/rpc_ui_spec.lua`, `tests/smoke/client_smoke.lua` |

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
