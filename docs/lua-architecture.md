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
  -> pi.ui.transcript
  -> pi.ui.transcript_view -> pi.ui.render
  -> pi.ui.image_preview
  -> pi.ui.input / command_menu / permission / widget

pi.ui.render
  -> pi.ui.render.*
```

`scripts/check-lua-architecture.mjs` tokenizes executable Lua while ignoring
comments and strings. Its policy test rejects forbidden layer edges, unapproved
literal-require cycles, and new direct access to private Chat component fields.
The two existing late `require("pi")` UI action edges and the remaining
sibling-component Chat accesses are explicit, count-bounded migration
exceptions. Task 02 removed the Runtime/command facade leaks; Task 03 removes
the remaining internal UI exceptions rather than allowing that debt to grow.

The temporary exception budget is:

| Exception | Current budget | Removal task |
| --- | ---: | --- |
| `pi.ui.input -> pi` late action dispatch | 1 edge | Task 03 |
| `pi.ui.transcript_view -> pi` late action dispatch | 1 edge | Task 03 |
| CommandMenu/PermissionPanel access to sibling Chat components | 6 accesses | Task 03 |

The checker requires the exact current count. Adding a matching access fails, and
removing one requires shrinking the reviewed budget in the same change.

## State Ownership

| State | Lua owner |
| --- | --- |
| RPC process, framing, pending requests | `pi.client` / `pi.protocol` |
| Per-project clients and RPC event projection | `pi.runtime` |
| Display correlation queue, discovered-command map, refresh flags, direct-RPC Bash request | `pi.runtime` |
| Bounded display items, tool correlation, retention counters | `pi.ui.transcript` |
| Transcript buffer, render cache/timer, semantic ranges, image placements | `pi.ui.transcript_view` |
| Layout choice, top-level chat window, display mirrors, coordination | `pi.ui.chat` |
| Prompt and footer buffers/windows | `pi.ui.input` |
| Command-menu buffer/window/matches/selection | `pi.ui.command_menu` |
| Permission queue, inline projection, focus trap | `pi.ui.permission` |
| Widget values and widget buffers/windows | `pi.ui.widget` |
| Temporary enlarged-image buffer/window | `pi.ui.image_preview` |
| Image preparation/cache and terminal placement backend | `pi.ui.image` / `pi.ui.image_backend` |

`Transcript` is a bounded Neovim display projection, not session storage.
Releasing or clearing local bodies does not alter Pi's authoritative session.
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
cannot project into the replacement Chat. The remaining direct component
accesses are internal sibling-component exceptions with fixed occurrence
budgets for Task 03, not supported external APIs.

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
Extmarks, and terminal image synchronization.

## Lifecycle

Closing a Chat stops its activity animation, closes the image preview, clears
transcript image placements, cancels permission requests fail-closed, closes
component windows, and closes the top-level window. Destroying additionally
stops the transcript render timer, deletes owned scratch buffers, releases
transcript images and counters, clears component state, and unregisters the
project instance. Component `destroy()` operations are idempotent.

Permission decisions remain in the bundled permission Extension. The Lua
permission panel only displays structured requests, validates interaction,
captures focus, and returns a response. Missing UI, cancellation, and teardown
continue to return a blocking response.

## Test Ownership

| Owner | Primary tests |
| --- | --- |
| Shared message/format/catalog helpers | `tests/lua/shared_owners_spec.lua` |
| Renderer facade and focused renderers | `tests/lua/ui/render_spec.lua`, image/Markdown specs |
| Transcript model | `tests/lua/ui/transcript_spec.lua`, `regression/output_budget_spec.lua` |
| Transcript view and render cache | `regression/performance_spec.lua`, Chat UI specs |
| Image preview/backend lifecycle | image Chat/backend lifecycle specs |
| Component ownership and layout | Chat, layout, widget, and permission specs |
| Chat facade contract | `tests/lua/ui/chat_facade_spec.lua` |
| Runtime per-project orchestration | `tests/lua/runtime_spec.lua` |
| RPC-to-UI integration | `tests/lua/integration/rpc_ui_spec.lua` |
| Permission authority | Lua permission spec plus Extension policy tests |

Run `make test-file TEST=<path>` for one known Lua or Extension test owner. Run
`make test` for the complete deterministic Lua, Extension, and repository policy
suite; `make format-check` for formatting; and `make smoke` for installed Pi RPC
and Extension loading without a model call.
