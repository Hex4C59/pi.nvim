# Module Split Plan

This document is the executable plan for splitting the two oversized modules in
pi.nvim: `lua/pi/init.lua` (953 lines) and `lua/pi/ui/chat.lua` (1958 lines).

## Goals and Principles

1. **Move code, do not change architecture.** No new frameworks, no event-bus
   rewrite, no behavioral changes. The dependency direction
   (`init → client/chat/context`, `chat → render`) is already sound and stays.
2. **Public API is frozen.** Every export the test suite touches must resolve
   to the same behavior before and after each phase:
   - `require("pi")` — all `M.*` command functions (see Frozen Exports below)
   - `require("pi.ui.chat")` — `Chat`, `text_content`, `format_count`,
     `builtin_commands`, `complete`
   - `require("pi.client").Client` (mocked by `tests/init_spec.lua`)
3. **One phase = one green `make test`.** Each phase is a separate commit.
   Tests are expected to pass with **zero modifications** — the suite pins the
   frozen exports, which is what makes the split verifiable.
4. **Keep the monkey-patch contract.** `tests/commands_spec.lua` replaces
   `pi.select_model` etc. at runtime and then calls `pi.submit("/model ...")`.
   `M.submit` must therefore dispatch through `M.*` references, never through
   direct calls into a commands module:

   ```lua
   -- M.submit must keep calling M.<cmd>, not commands.model.<fn>:
   elseif command == "model" then
     M.select_model(root, arguments)
   ```

   A direct call would silently break `commands_spec`.

## Current State

| File | Lines | Responsibilities (mixed) |
| --- | --- | --- |
| `lua/pi/init.lua` | 953 | setup, command dispatch, 27 command implementations, event dispatch (`attach`), client lifecycle, prompt send logic, RPC-unavailable command table |
| `lua/pi/ui/chat.lua` | 1958 | Chat class (layout, buffers, transcript model, interaction), command menu subsystem (~280 lines), input/status area (~300 lines), highlights table (166 lines), welcome animation, text helpers |

All other modules (`client.lua` 223, `protocol.lua` 78, `config.lua` 106,
`context.lua` 156, `ui/dialog.lua` 90, `ui/render.lua` 1392, `health.lua` 25)
are within healthy size and are **not touched** by this plan.

## Target Structure

```
lua/pi/
├── init.lua              # ~250 lines: setup, command dispatch table, lifecycle
├── runtime.lua           # NEW ~200 lines: shared session state + helpers
├── commands/
│   ├── model.lua         # NEW: select/cycle model and thinking level
│   ├── session.lua       # NEW: new/compact/status/tree/fork/clone/name/export/resume/commands
│   ├── action.lua        # NEW: ask/visual/buffer/bash/abort/copy
│   └── ui.lua            # NEW: layout/settings/hotkeys
└── ui/
    ├── chat.lua          # ~1100 lines: Chat core only
    ├── command_menu.lua  # NEW ~280 lines: CommandMenu class + command catalog
    ├── input.lua         # NEW ~300 lines: InputArea class + completion
    ├── highlights.lua    # NEW ~180 lines: setup_highlights + blend
    └── render.lua        # untouched
```

## Frozen Exports (must keep resolving)

| Module | Exports |
| --- | --- |
| `require("pi")` | `setup`, `chat`, `submit`, `ask`, `visual`, `buffer`, `abort`, `select_model`, `select_thinking_level`, `cycle_model`, `cycle_thinking_level`, `settings`, `layout`, `new_session`, `compact`, `status`, `tree`, `fork`, `clone`, `name_session`, `export_session`, `resume`, `commands`, `hotkeys`, `bash`, `copy_last_response`, `track_buffer`, `stop`, `stop_all` |
| `require("pi.ui.chat")` | `Chat`, `text_content`, `format_count`, `builtin_commands`, `complete` |
| `require("pi.client")` | `Client` |

`tests/commands_spec.lua` pins the `pi` exports and the `builtin_commands`
catalog (name + order); `tests/ui_spec.lua` and `tests/layout_spec.lua` pin
`Chat` behavior. These two files are the primary regression gates.

## Phase 1 — Extract `runtime.lua` and `commands/` (init.lua: 953 → ~250)

### 1a. New file `lua/pi/runtime.lua`

Move the shared session-state helpers out of `init.lua` verbatim (no
behavioral change):

| Function/table (from init.lua) | Destination |
| --- | --- |
| `clients` / `chats` tables | `runtime` |
| `client_root`, `chat_for`, `get_client` | `runtime` |
| `notify_error` | `runtime` |
| `refresh_commands`, `refresh_stats`, `refresh_state`, `reload_session` | `runtime` |
| `pending_display`, `remove_pending_display` | `runtime` |
| `with_prompt`, `send_prompt` | `runtime` |
| `rpc_unavailable_commands` | `runtime` (exported) |

`runtime.lua` requires `pi.config`, `pi.client` (for `Client`), `pi.context`,
`pi.ui.chat` (for `Chat` + `text_content`), `pi.ui.dialog`. All functions keep
their exact bodies; only the `chat_ui` local is renamed to a `require` at the
top of `runtime.lua`.

`init.lua` then forwards: `local runtime = require("pi.runtime")` and replaces
its local definitions with references (e.g. `local get_client = runtime.get_client`).
Keep local aliases so no call site changes.

### 1b. New directory `lua/pi/commands/`

Each module requires `pi.runtime` for `get_client`, `chat_for`,
`notify_error`, `reload_session`, `refresh_state`, `refresh_stats`,
`with_prompt`, `send_prompt`. Function bodies move verbatim.

| File | Functions (moved from init.lua) | Extra local deps |
| --- | --- | --- |
| `commands/model.lua` | `select_model`, `select_thinking_level`, `cycle_model`, `cycle_thinking_level` | `chat_ui.format_count` |
| `commands/session.lua` | `new_session`, `compact`, `status`, `tree`, `fork`, `clone`, `name_session`, `export_session`, `resume`, `commands` | `entry_text`, `flatten_tree` move here; `text_content`, `builtin_commands` from `pi.ui.chat` |
| `commands/action.lua` | `ask`, `visual`, `buffer`, `bash`, `abort`, `copy_last_response` | `context`, `config` |
| `commands/ui.lua` | `layout`, `settings`, `hotkeys` | `chat_ui` |

`init.lua` re-exports so the public surface is unchanged:

```lua
local model_cmds = require("pi.commands.model")
M.select_model = model_cmds.select_model
-- ... one line per frozen export, no wrapper functions
```

`M.submit` stays in `init.lua` and **keeps dispatching through `M.*`**
(see Goal 4). `M.chat`, `M.setup`, `M.track_buffer`, `M.stop`, `M.stop_all`
stay in `init.lua` as-is.

### Verify Phase 1

```bash
make test      # commands_spec is the gate: dispatch + monkey-patch + catalog
make format-check
```

`git diff --stat` after each commit should show only moved lines and new
`require`/forwarding lines, no other edits.

## Phase 2 — Split `chat.lua` (1958 → ~1100)

### 2a. New file `lua/pi/ui/highlights.lua` (~180 lines)

Move `blend` and `setup_highlights` verbatim. Export `setup()` (wraps
`setup_highlights`) and keep `blend` module-local unless another module needs
it. `chat.lua` calls `require("pi.ui.highlights").setup()` where it previously
called `setup_highlights()`.

### 2b. New file `lua/pi/ui/command_menu.lua` (~280 lines)

Extract the command-completion subsystem as a `CommandMenu` class holding its
own state (`command_buf`, `command_win`, `command_matches`,
`command_selected`, `command_first`, `command_start_col`, `command_base`),
constructed with a chat reference:

```lua
local CommandMenu = {}
CommandMenu.__index = CommandMenu
function CommandMenu.new(chat) ... end   -- takes namespace, name_buffer, truncate_display via closure or chat field
```

| Function (from chat.lua) | Destination |
| --- | --- |
| `available_commands` (396) | module-local in `command_menu.lua` |
| `builtin_commands` (exported) | defined here, exported; `chat.lua` forwards `M.builtin_commands` |
| `_command_completion_context`, `_command_menu_visible`, `_ensure_command_buffer`, `_close_command_menu`, `_render_command_menu`, `_layout_command_menu`, `_open_command_menu`, `_update_command_menu`, `_show_command_completion`, `_select_command`, `_accept_command_completion` | `CommandMenu` methods |

`chat.lua` keeps thin delegating methods with the **same names and signatures**
(`Chat:_open_command_menu()` → `self.command_menu:open()` etc.). `Chat:new`
creates the menu; `Chat:close` and `Chat:_close_command_menu` call
`self.command_menu:close()`.

Shared resources that cross the boundary:
- `namespace` (extmark namespace): owned by `chat.lua`, passed into
  `CommandMenu.new(chat)` — the menu reads `chat.namespace` or receives it as a
  constructor arg. Do not create a second namespace; extmark priorities and
  clears must stay on the same one.
- `name_buffer`, `isolate_input_completion`, `truncate_display`: moved to
  `command_menu.lua` as module-locals **if and only if** no other module uses
  them (see 2c); otherwise they live in `input.lua` or stay in `chat.lua` and
  are passed in.

### 2c. New file `lua/pi/ui/input.lua` (~300 lines)

Extract the input/status area as an `InputArea` class holding
(`input_buf`, `input_win`, `status_buf`, `status_win`, input height, queue,
`command_matches` is NOT here — menu owns it).

| Function (from chat.lua) | Destination |
| --- | --- |
| `M.complete` (414) | `InputArea.complete` (Neovim `completefunc` entry) |
| `isolate_input_completion` (88) | module-local |
| `name_buffer` (77) | module-local (shared with `chat.lua` — if `chat.lua` still needs it, move to `ui/buffers.lua` instead and both require it) |
| `_update_input_chrome`, `_status_text`, `_render_status`, `_desired_input_height`, `_resize_input`, `_focus_input`, `_ensure_input_buffer`, `_ensure_status_buffer` | `InputArea` methods |
| `text_content`, `format_count`, `truncate_display`, `compose_line`, `append_chunk`, `format_percent` | module-local helpers in `input.lua` **only if unused elsewhere**; otherwise keep in `chat.lua` |

`chat.lua` keeps thin delegates with unchanged names, and forwards
`M.complete = input_area_complete` (or `M.complete = require("pi.ui.input").complete`).

Check before moving helpers: `grep -n "text_content\|format_count\|truncate_display" lua/pi/ui/chat.lua lua/pi/init.lua` — every module-local that is referenced from more than one future module must either stay in `chat.lua` (and be passed in) or move to a shared location. Prefer **keeping shared helpers in `chat.lua`** for this phase; consolidating them into a `ui/text.lua` is a possible later cleanup, not part of this plan.

### 2d. Optional (deferred): welcome animation → `ui/welcome.lua`

The animation state (`welcome_animation_timer`, `welcome_animation_frame`,
`welcome_logo_palette`) is module-level in `chat.lua` and coupled to the
`instances` table via `has_open_chat`. Extracting it is independent and
low-value; do it only if `chat.lua` is still over ~1200 lines after 2a–2c.
If extracted: `ui/welcome.lua` exports `sync(instances_lookup)` and
`stop()`, and owns the timer + palette.

### Verify Phase 2

```bash
make test      # ui_spec (460 lines) and layout_spec are the gates
make format-check
```

## Phase 3 — Cleanup and docs

1. `make test` and `make format-check` fully green.
2. Confirm `git diff --stat` totals: `init.lua` ≈ −700 lines, `chat.lua`
   ≈ −850 lines, no unexpected diffs in `client.lua`/`protocol.lua`/`render.lua`.
3. `grep -rn "require(\"pi\")" lua/` — every `require("pi")` from inside
   `lua/pi/` must be gone (submodules require their direct dependencies, not
   the entry module). This prevents circular requires.
4. Optionally add a `docs/` note or README "Architecture" section listing the
   module map; not required for the split itself.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| `commands_spec` monkey-patch silently broken by direct module calls | `M.submit` keeps dispatching through `M.*` (Goal 4); `commands_spec` catches any regression |
| Circular require (`pi.ui.chat` ↔ new submodules) | `chat.lua` delegates but does not re-import itself; new modules require `pi.ui.chat` for `Chat` type only via constructor, or take shared helpers as args |
| Shared helpers (`text_content`, `truncate_display`, `namespace`) used by multiple new modules | Decide ownership per helper before writing each phase; default = keep in `chat.lua`, pass as constructor args |
| Extmark namespace split into two | Single `namespace` owned by `chat.lua`, injected into `CommandMenu` |
| Behavioral drift hidden inside a move | No behavior edits in the same commit as a move; each phase is move-only + forwarding |
| `format-check` fails after moves (stylua grouping) | Run `stylua lua` after each phase before committing |

## Commit Sequence (one commit per step, 6–7 commits total)

1. `refactor: extract pi.runtime shared session helpers`
2. `refactor: move commands into lua/pi/commands/*`
3. `refactor: extract ui/highlights`
4. `refactor: extract CommandMenu from chat.lua`
5. `refactor: extract InputArea from chat.lua`
6. `refactor: (optional) extract welcome animation`
7. `docs: module split follow-up notes` (if any)

Each commit: `make test` green, `stylua lua` clean, `git diff --stat` shows
only moves + forwarding lines.

## Explicit Non-Goals

- No change to RPC protocol handling, client lifecycle, or render logic.
- No new dependencies, no plugin structure changes (`plugin/pi.lua`,
  `lua/pi.lua` vs `lua/pi/init.lua` stays as-is).
- No test-file edits; if a test must change, the plan has a flaw — stop and
  reconsider before editing the test.
- No restructuring of `render.lua`, `client.lua`, `protocol.lua`, `context.lua`,
  `config.lua`, `dialog.lua`, `health.lua`.
