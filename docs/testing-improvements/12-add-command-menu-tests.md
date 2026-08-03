# Task 12: Add Focused CommandMenu Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 10
>
> Blocks: Tasks 13 through 15

## 1. Goal

Move slash-command completion, fuzzy matching, command-menu buffer/window,
selection, acceptance, and cleanup assertions out of the broad Chat spec into a
direct test for `pi.ui.command_menu`.

The CommandMenu presents a catalogue supplied by Chat/runtime. It does not
decide whether a command is native, RPC-backed, Extension-owned, or unavailable;
that classification remains owned by command catalogue and dispatch modules.

## 2. Target File

Create:

```text
tests/lua/ui/command_menu_spec.lua
```

Primary owner:

```text
lua/pi/ui/command_menu.lua
```

Keep dispatch semantics in:

```text
tests/lua/commands/dispatch_spec.lua
tests/lua/commands/rpc_limitations_spec.lua
tests/lua/integration/rpc_ui_spec.lua
```

## 3. Fixture Design

Construct CommandMenu with:

- a minimal fake Chat exposing input text, input window, canvas window, and the
  action used when a completion is accepted;
- a deterministic command list containing native, RPC limitation, Extension,
  and prompt-template examples;
- a scratch parent window with controlled width/height;
- injected buffer naming/truncation helpers where the constructor expects them;
  and
- a local instances table when testing module-level completion.

Record accepted command text and selection changes. Do not start a Pi process or
send prompts.

## 4. Catalogue and Completion Cases

Cover module-level and instance-level completion for:

- leading `/` detection;
- no completion for ordinary prompt text;
- exact prefix matches;
- fuzzy subsequence matches such as `/smd`;
- stable match-position indices;
- case behavior according to the current contract;
- stable catalogue order;
- deduplication between built-in and dynamic commands;
- command kind/description preserved as presentation metadata;
- no mutation of the source catalogue; and
- completion start column for text before/after the slash where supported.

Do not assert that TUI-only commands execute. Their displayed limitation and
dispatch behavior remain covered in command tests.

## 5. Buffer and Window Cases

Move assertions for:

- lazy menu buffer creation;
- nofile/scratch semantics and `pi_kind` metadata;
- menu window above the prompt frame;
- full alignment with the Chat canvas edges;
- nonfocusable window retaining input focus;
- no detached decorative border;
- menu surface matching the canvas;
- selected row using a distinct local surface;
- row display width never exceeding the window;
- matched-character Extmarks;
- selected-row Extmark;
- native popup menu remaining hidden; and
- `owns_buffer` and public buffer/window accessors.

Test wide, narrow, and insufficient-height parent geometry. If no row can be
displayed, the component should close or remain hidden according to its current
contract rather than creating an invalid window.

## 6. Selection and Acceptance

Cover:

- initial selected item;
- moving forward/backward;
- wraparound behavior if supported;
- selection retained or reset when the match set changes;
- accepting the selected completion;
- inserted command text and cursor placement;
- accepting with no matches as a no-op;
- closing after acceptance; and
- prompt focus preserved.

Use direct methods for deterministic unit behavior and one keymap-driven case in
InputArea/Chat integration to prove wiring. Do not duplicate every key binding in
this component spec.

## 7. Update and Lifecycle Cases

Cover:

- opening only when completion context is valid;
- updating rows after input changes;
- closing when slash context disappears;
- closing when the parent/prompt window is invalid;
- repeated open/close;
- buffer reuse where intended;
- `destroy` closing/deleting owned resources;
- idempotent destroy; and
- scheduled update after destroy becoming a no-op.

No menu window or buffer should remain after the component is destroyed.

## 8. Migration Procedure

1. Move fuzzy-completion assertions from `chat_spec.lua`.
2. Move menu buffer/window/layout/highlight assertions.
3. Move selection/acceptance assertions.
4. Retain one Chat wiring test proving typing invokes the component.
5. Run direct component and Chat facade specs after each move.
6. Run command dispatch/integration tests to protect ownership boundaries.

## 9. Verification

```bash
make test-file TEST=tests/lua/ui/command_menu_spec.lua
make test-file TEST=tests/lua/ui/input_spec.lua
make test-file TEST=tests/lua/ui/chat_spec.lua
make test-file TEST=tests/lua/commands/dispatch_spec.lua
make test-file TEST=tests/lua/commands/rpc_limitations_spec.lua
make test-file TEST=tests/lua/integration/rpc_ui_spec.lua
make test-lua
make format-check
```

## 10. Risks

- Fuzzy-match tests can accidentally lock in an incidental scoring algorithm.
  Protect stable ordering and match positions required for highlighting, not an
  undocumented score value.
- Menu geometry depends on prompt/canvas windows. Keep one Chat integration case
  after direct tests.
- Dynamic Extension command discovery is RPC behavior and remains in the fake
  RPC integration test.
- Clean all Extmarks, buffers, windows, and scheduled callbacks.

## 11. Completion Checklist

- [ ] `ui/command_menu_spec.lua` exists and runs independently.
- [ ] Exact, prefix, fuzzy, deduplicated, and no-match completion is covered.
- [ ] Menu geometry, surfaces, Extmarks, and focus behavior are covered.
- [ ] Selection, acceptance, update, close, and destroy are covered.
- [ ] TUI/RPC/Extension dispatch ownership remains in command/integration tests.
- [ ] Chat retains one wiring case but no detailed menu implementation tests.
- [ ] Focused component, command, integration, full Lua, and format checks pass.
