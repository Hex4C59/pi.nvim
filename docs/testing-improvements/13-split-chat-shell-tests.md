# Task 13: Split Chat Shell and Cross-Component Layout Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 12
>
> Blocks: Tasks 14 and 15

## 1. Goal

Create a focused Chat-shell spec for construction, component wiring, window
orchestration, ownership delegation, responsive layout, and welcome integration.

By this task, InputArea, CommandMenu, Transcript, and TranscriptView already have
direct tests. The Chat shell test must cover their composition without retesting
their internal algorithms.

## 2. Target Structure

Create:

```text
tests/lua/ui/chat/shell_spec.lua
```

Retain:

```text
tests/lua/ui/layout_spec.lua
tests/lua/ui/chat_spec.lua
```

`layout_spec.lua` remains the broad configuration matrix for right, bottom, tab,
and float positions. `chat/shell_spec.lua` covers one representative position in
depth. `chat_spec.lua` remains temporarily until Tasks 14 and 15 finish.

## 3. Construction and Dependency Wiring

Construct one Chat with deterministic config and verify it creates exactly one
instance of each current component owner:

- CommandMenu;
- InputArea;
- PermissionPanel;
- WidgetArea;
- image backend;
- Transcript;
- TranscriptView; and
- ImagePreview.

Assert callbacks are wired in the correct direction:

- Transcript changes invalidate/schedule TranscriptView.
- TranscriptView reads structured Transcript items.
- image backend changes invalidate the view.
- InputArea and overlays ask Chat for display state.
- Chat delegates ownership checks rather than duplicating component buffers.

Do not assert every private field. Test observable delegation through public or
stable facade methods.

## 4. Open and Window Shell

Move/retain cross-component assertions for:

- `open` creates the main canvas and component windows;
- requested input focus is honored;
- opening an already open Chat is idempotent;
- main buffer options support wrapping and suppress list/cursorline artifacts;
- prompt and status windows are relative to the canvas;
- overlays do not steal focus unexpectedly;
- `is_open` reflects actual window validity; and
- multiple project Chat instances do not claim one another's buffers.

Detailed prompt/status buffer options belong to Task 11.

## 5. Ownership Delegation

For every component-created buffer available in the fixture, assert
`Chat:owns_buffer` returns true. Assert false for:

- an unrelated normal buffer;
- a buffer owned by another Chat root;
- deleted buffer IDs; and
- nil/invalid input according to the current contract.

Then invalidate or destroy individual component buffers and verify Chat's answer
tracks the component rather than stale mirrored fields.

## 6. Representative Layout Composition

At one representative sidebar position, assert:

- main canvas width/height are valid;
- prompt aligns with both canvas edges;
- status row aligns with the prompt/canvas;
- command menu is above the prompt when visible;
- permission/widget transcript overlays contribute to reserved height;
- input growth causes relayout without overlap;
- narrow/short viewport keeps every window within editor bounds; and
- text in each UI element fits its allocated width.

Do not duplicate the full position matrix in `layout_spec.lua`. Instead, add a
cross-reference in comments or assertion names when a shell invariant is also
protected across positions there.

## 7. Welcome and Global UI Integration

Move the Chat-level welcome assertions that require an actual buffer:

- welcome appears after opening;
- welcome remains above the first conversation turn;
- welcome semantic highlights are applied as Extmarks;
- global welcome palette updates after ColorScheme;
- welcome animation advances only while at least one Chat is open; and
- closing the last Chat stops the shared welcome timer.

Detailed welcome text/layout stays in `render/welcome_spec.lua`. The shell spec
asserts buffer application and global lifecycle only.

## 8. State Projection Wiring

Use `Chat:update_state` with representative core state and assert it updates the
display mirror consumed by components:

- path/session label;
- model;
- thinking level;
- auto-compaction flag;
- statistics;
- queue; and
- reported permission mode.

Wait for authoritative update methods; do not add optimistic local state.
Permission decision semantics remain in Extension tests.

## 9. Migration Procedure

1. Create the shell fixture and cleanup path.
2. Move only construction/layout/welcome integration assertions from
   `chat_spec.lua`.
3. Keep component-internal assertions in Tasks 11/12 and existing panel specs.
4. Keep transcript mouse/toggle behavior for Task 14.
5. Keep activity/close/destroy behavior for Task 15.
6. Run shell, layout, component, and original Chat specs after each cluster.

## 10. Verification

```bash
make test-file TEST=tests/lua/ui/chat/shell_spec.lua
make test-file TEST=tests/lua/ui/layout_spec.lua
make test-file TEST=tests/lua/ui/input_spec.lua
make test-file TEST=tests/lua/ui/command_menu_spec.lua
make test-file TEST=tests/lua/ui/chat_spec.lua
make test-lua
make format-check
```

## 11. Risks

- Shared global welcome timers can survive a failed assertion. Always close all
  Chat instances through protected cleanup.
- Avoid direct private-field checks that recreate component ownership in Chat
  tests.
- Autocommands are global. Ensure the spec does not clear user/repository groups
  needed by later tests in the same Neovim process.
- Geometry assertions must use the actual editor dimensions and remain valid on
  Neovim 0.10.

## 12. Completion Checklist

- [ ] `ui/chat/shell_spec.lua` exists and runs independently.
- [ ] Construction and component wiring are covered once.
- [ ] Buffer ownership delegates to components.
- [ ] Representative cross-component layout is covered without duplicating the
      full layout matrix.
- [ ] Welcome application and shared timer lifecycle are covered.
- [ ] Display state updates do not become authoritative local state.
- [ ] All Chat instances, timers, windows, and buffers are cleaned.
- [ ] Focused shell/component/layout tests and full Lua suite pass.
