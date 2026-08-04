# Lua Frontend Architecture

This document describes the implemented Lua module boundaries in pi.nvim. The
frontend remains a display and interaction layer over Pi RPC: Pi core owns
sessions, model state, tools, queues, and compaction, while bundled Extensions
own workflow and permission policy.

## Dependency Direction

```text
plugin/pi.lua
  -> pi.init
     -> pi.commands.*
     -> pi.runtime
        -> pi.client -> pi.protocol
        -> pi.ui.chat
        -> pi.ui.dialog

pi.commands.*
  -> pi.runtime
  -> pi.message / pi.format / pi.commands.catalog

pi.ui.chat
  -> pi.ui.chat.registry / pi.ui.chat.shell
  -> pi.ui.transcript
     -> pi.ui.transcript.projection / retention / history
  -> pi.ui.transcript.view -> pi.ui.render
  -> pi.ui.image.window / pi.ui.image.backend
  -> pi.ui.input / command_menu / permission / widget

pi.ui.image
  -> pi.ui.image.source / preview / scheduler

pi.ui.render
  -> pi.ui.render.*
```

`scripts/check-lua-architecture.mjs` tokenizes executable Lua while ignoring
comments and strings. Its policy test rejects forbidden layer edges, UI modules
that load the top-level `pi` facade for action dispatch, literal-require cycles,
direct access to private Chat component fields, and Runtime-owned state placed
on Client objects. It also prevents Transcript and renderer modules from
bypassing the stable image facade, pure Transcript helpers from depending back
on the model or View, and TranscriptView from importing model state. There are
no reviewed cycle or facade-leak exceptions.

Frontend actions flow from `pi.init` into Runtime, which binds them to a project
root and passes them to the Chat composition root. Chat then supplies named
callbacks to InputArea and TranscriptView. UI modules do not discover actions
through a late top-level require.

## State Ownership

| State | Lua owner |
| --- | --- |
| RPC process, framing, pending requests | `pi.client` / `pi.protocol` |
| Per-project clients and RPC event projection | `pi.runtime` |
| Display correlation queue, discovered-command map, refresh flags, direct-RPC Bash request | `pi.runtime` |
| Bounded display items, item IDs, tool correlation, retention counters | `pi.ui.transcript` |
| Bounded content copies and summaries | `pi.ui.transcript.projection` |
| Release candidate ordering and retained-byte total calculation | `pi.ui.transcript.retention` |
| Persisted-message to display-event ordering | `pi.ui.transcript.history` |
| Transcript buffer, render cache/timer, semantic ranges, image placements | `pi.ui.transcript.view` |
| UI namespace, Chat registry, global UI autocmds, shared welcome timer | `pi.ui.chat.registry` |
| Layout choice, top-level chat window, responsive geometry | `pi.ui.chat.shell` |
| Component composition, display mirrors, activity state, frontend delegation | `pi.ui.chat` |
| Prompt and footer buffers/windows | `pi.ui.input` |
| Command-menu buffer/window/matches/selection | `pi.ui.command_menu` |
| Permission queue, inline projection, focus trap | `pi.ui.permission` |
| Widget values and widget buffers/windows | `pi.ui.widget` |
| Per-block `_pi_image` state and stable image API | `pi.ui.image` |
| MIME, decoded source, dimensions, private cache | `pi.ui.image.source` |
| RGBA block conversion and dynamic preview highlights | `pi.ui.image.preview` |
| Preview queue, timers, converter processes, cancellation | `pi.ui.image.scheduler` |
| Terminal backend state and placement handles | `pi.ui.image.backend` / `image.backends.*` |
| Temporary enlarged-image buffer/window | `pi.ui.image.window` |

`Transcript` is a bounded Neovim display projection, not session storage.
Releasing or clearing local bodies does not alter Pi's authoritative session.
Streaming and persisted history both pass through
`pi.ui.transcript.projection`; those pure transformations copy and bound caller
tables. `pi.ui.transcript.retention` only orders release candidates and totals
owned byte categories. The Transcript model alone applies releases, assigns
item IDs, correlates tool calls, owns counters, and emits change notifications.
`pi.ui.transcript.history` emits ordered display events but never creates model
identity or state.
Runtime normally calls the `Chat` facade, whose mutation methods delegate to the
transcript model. Runtime and command modules use facade methods for permission
activity, projection reset, layout, process detail, and display-state reads.
`Chat.root` is initialized once as immutable composition identity; external
callers use `Chat:project_root()` rather than treating the display context path
as project identity. A display-state snapshot is detached from Chat, so changing
the returned table cannot mutate UI state.

Runtime keeps display correlation, discovered commands, stats refresh state,
direct-RPC Bash identity, and the Client event unsubscriber in one internal
per-project record tied to the current Client identity. These values are never
attached to Client objects. Late events and callbacks from a replaced Client
cannot project into the replacement Chat.

Chat is the only composition root that knows all child components. InputArea,
CommandMenu, PermissionPanel, and WidgetArea receive explicit dependency tables
and never read a sibling field. Shell receives window, buffer, state, and action
providers from Chat; it does not own component behavior.

## Rendering

`pi.ui.render` is the stable public facade. It preserves `render`,
`render_welcome`, `split_lines`, `result_text`, `format_duration`, and
`format_elapsed`. Implementation is divided by presentation responsibility:

| Module | Responsibility |
| --- | --- |
| `render.canvas` | Collect lines, semantic marks, and image descriptors |
| `render.text` | Line, width, byte, and duration primitives |
| `render.code` | Language detection and bounded Tree-sitter highlight cache |
| `render.media` | Terminal image descriptors, block previews, text fallback |
| `render.markdown` | Terminal-native Markdown and linked images |
| `render.messages` | User, assistant, thinking, status, and stop reasons |
| `render.tools` | Tool headers, output, diffs, truncation, and row ranges |
| `render.process` | Process segmentation, summaries, and expansion |
| `render.welcome` | Responsive welcome surface |
| `render.engine` | Facade orchestration only |

Renderer modules produce values and do not create or mutate Neovim buffers or
windows. `TranscriptView` applies their output and retains stable-prefix render
caching, bounded projection accounting, coalesced redraws, scroll following,
Extmarks, and terminal image synchronization. It receives items, state, byte
counts, actions, and lifecycle callbacks through injected providers and does
not import the Transcript model. `pi.ui.transcript_view` is a stateless
compatibility alias for `pi.ui.transcript.view`.

`pi.ui.image` is the stable facade used by Transcript, TranscriptView, and
renderers. It is the only module that attaches or clears `_pi_image` on a
content block. Source loading, preview conversion, scheduling, backend
placement, and enlarged-window lifecycle are delegated to focused owners below
`pi.ui.image.*`. The former `pi.ui.image_backend`, `pi.ui.image_backends.snacks`,
and `pi.ui.image_preview` paths are compatibility aliases without state.

## Lifecycle

Closing a Chat delegates window reset to Shell: it stops the per-Chat activity
animation, closes the image preview, clears transcript image placements,
cancels permission requests fail-closed, closes component windows, and closes
the top-level window. Destroying additionally stops the transcript render timer,
deletes owned scratch buffers, releases transcript images and counters, clears
component state, and unregisters the project from Registry. The shared welcome
timer stops when no registered Chat is open. Chat, Registry, and component
`destroy()` operations are idempotent.

Permission decisions remain in the bundled permission Extension. The Lua
permission panel only displays structured requests, validates interaction,
captures focus, and returns a response. Missing UI, cancellation, and teardown
continue to return a blocking response.

Bundled security Extensions keep event registration in the three TypeScript
entries. `extensions/lib/security/permission.mjs` owns modes, approvals,
prompting, tool-set transitions, and fail-closed permission evaluation;
`workspace.mjs` owns read-only canonical-root enforcement; and
`session-root.mjs` owns session-header validation and the final same-root switch
guard. `paths.mjs`, `tool-call.mjs`, `guidance.mjs`, and `file-header.mjs` are
focused shared helpers. No aggregate security index or policy state remains.

## Test Ownership

| Owner | Primary tests |
| --- | --- |
| Shared message/format/catalog helpers | `tests/lua/shared_owners_spec.lua` |
| Renderer facade and focused renderers | `tests/lua/ui/render_spec.lua`, `tests/lua/ui/render/`, image/Markdown specs |
| Transcript projection, retention, and history helpers | `tests/lua/ui/transcript/` |
| Transcript model | `tests/lua/ui/transcript_spec.lua`, `regression/output_budget_spec.lua` |
| Transcript view and render cache | `tests/lua/ui/transcript_view_spec.lua`, `regression/performance_spec.lua` |
| Image preview/backend lifecycle | image Chat/backend lifecycle specs |
| Image source, preview, scheduler, backend, and window owners | `tests/lua/ui/image/` |
| Chat registry/global lifecycle | `tests/lua/ui/chat/registry_spec.lua` |
| Chat shell and responsive layout | `tests/lua/ui/chat/shell_spec.lua` |
| Chat transcript and input interactions | `tests/lua/ui/chat/interaction_spec.lua`, `interactions_spec.lua` |
| Chat activity and component lifecycle | `tests/lua/ui/chat/lifecycle_spec.lua` |
| Input and command-menu ownership | `tests/lua/ui/input_spec.lua`, `command_menu_spec.lua` |
| Widget and permission ownership | `tests/lua/ui/widget_spec.lua`, `permission_spec.lua` |
| Chat facade contract | `tests/lua/ui/chat/facade_spec.lua` |
| Runtime per-project orchestration | `tests/lua/runtime_spec.lua` |
| RPC-to-UI integration | `tests/lua/integration/rpc_ui_spec.lua` |
| Permission, path, workspace, session-root authority | `tests/extensions/security/` plus Lua permission presentation spec |

Run `make test-file TEST=<path>` for one known Lua or Extension test owner. Run
`make test` for the complete deterministic Lua, Extension, and repository policy
suite; `make format-check` for formatting; and `make smoke` for installed Pi RPC
and Extension loading without a model call.

## Architecture Closeout

The modular architecture work was closed on 2026-08-04 after the implemented
tree, dependency policy, state table, lifecycle contracts, and test ownership
map converged on the same boundaries:

- Chat, Transcript, TranscriptView, Image, and Render retain stable public
  facades while focused modules own composition, projection, resources, and
  pure rendering separately.
- Runtime state remains outside Client, UI components receive explicit
  providers instead of reaching through siblings, and only the Chat composition
  root may access child component fields.
- Permission, workspace, and session-root decisions remain in separate bundled
  Extension policies with thin TypeScript registration entries. Lua owns only
  native presentation and display mirrors.
- `scripts/check-lua-architecture.mjs` enforces layer direction, cycle absence,
  stable image boundaries, Runtime/Client separation, and Chat facade privacy
  with failing policy fixtures.
- Focused tests mirror renderer, transcript, view, input, menu, Chat, image, and
  Extension policy owners while facade and fake-RPC specs retain cross-owner
  composition and ordering coverage.

The current command surface, test inventory, harness decision, coverage
baseline, closeout timings, and residual test risks are maintained in
`tests/README.md`. Historical implementation checklists were removed after this
durable record was verified.
