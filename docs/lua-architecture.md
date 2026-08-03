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
The two existing late `require("pi")` UI action edges and the existing Chat
facade leaks are explicit, count-bounded migration exceptions; Tasks 02 and 03
in `docs/modular-architecture-plan.md` remove them rather than allowing the debt
to grow.

The temporary exception budget is:

| Exception | Current budget | Removal task |
| --- | ---: | --- |
| `pi.ui.input -> pi` late action dispatch | 1 edge | Task 03 |
| `pi.ui.transcript_view -> pi` late action dispatch | 1 edge | Task 03 |
| Runtime/command access to private Chat state | 4 accesses | Task 02 |
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
transcript model. The remaining direct component accesses are documented policy
exceptions with fixed occurrence budgets, not supported APIs. Runtime-owned
orchestration values that are temporarily stored on Client records remain
Runtime state and are migrated in the next architecture task.

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
| RPC-to-UI integration | `tests/lua/integration/rpc_ui_spec.lua` |
| Permission authority | Lua permission spec plus Extension policy tests |

Run `make test-file TEST=<path>` for one known Lua or Extension test owner. Run
`make test` for the complete deterministic Lua, Extension, and repository policy
suite; `make format-check` for formatting; and `make smoke` for installed Pi RPC
and Extension loading without a model call.
