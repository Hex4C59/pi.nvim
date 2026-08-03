# Task 11: Add Focused InputArea Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 10
>
> Blocks: Tasks 13 through 15

## 1. Goal

Move prompt-buffer, frame, footer, resize, focus, submission, and InputArea
resource-lifecycle assertions out of the broad Chat spec into a direct focused
test for `pi.ui.input`.

InputArea owns Neovim prompt/status presentation. It does not own Pi prompt queue
semantics, permission decisions, model state, or authoritative session state.

## 2. Target File

Create:

```text
tests/lua/ui/input_spec.lua
```

Primary owner:

```text
lua/pi/ui/input.lua
```

Keep cross-component window attachment and full Chat open/close behavior in
Tasks 13 and 15. Keep image attachment validation and backend behavior in the
existing image specs.

## 3. Fixture Design

Construct `InputArea` with a minimal fake Chat exposing only the callbacks and
state the component contract requires. Record calls for:

- prompt submission and project root;
- command-menu visibility, update, selection, and acceptance;
- permission-mode cycling;
- abort and model/thinking actions delegated through public Pi functions;
- mouse dispatch to the transcript;
- activity/reasoning status;
- queue counts;
- model/thinking/permission/context state; and
- attachment rendering where InputArea only presents already-validated data.

Create a parent scratch window when the component needs relative windows. Close
all component and parent windows/buffers at the end of each independent
scenario.

## 4. Buffer and Completion Isolation

Move existing prompt assertions for:

- `pi_prompt` filetype;
- editable prompt buffer;
- no placeholder content;
- disabled external completion marker;
- empty `complete`, `completefunc`, `omnifunc`, and `tagfunc` options;
- no swapfile and appropriate nofile semantics;
- stable `pi_kind` and project-root metadata; and
- `owns_buffer` before/after construction and destroy.

Add cases proving `ensure_input_buffer` and `ensure_status_buffer` are
idempotent and recreate invalid buffers safely.

Do not assert behavior of an installed completion plugin. The component contract
is the buffer-local isolation state.

## 5. Keymap Contract

Verify representative mappings and their ownership:

- Insert Enter submits without expression-map textlock.
- Up/Down navigate the command menu.
- Escape closes menu or exits the appropriate input state.
- permission-mode shortcut delegates rather than changing authoritative mode
  locally;
- mouse input can dispatch a transcript click without moving semantic policy
  into InputArea;
- abort/model/thinking bindings delegate to public actions; and
- mappings are buffer-local and removed with buffer destruction.

Avoid testing every alias through implementation details. Cover one path for
each distinct action and assert exact non-expression behavior where redraw
outside textlock is required.

## 6. Frame and Window Configuration

Move frame assertions for:

- square border characters;
- horizontal and vertical edge cells;
- distinct edge/corner semantic highlights;
- full-width top and bottom styled text;
- prompt surface and cursor/IME highlight groups;
- top padding via winbar;
- width aligned to the parent canvas;
- relative-window anchoring;
- nonfocusable one-line status window; and
- narrow-width truncation without overflow.

Test `window_config` as a component contract. Chat layout still owns the final
row/height allocation and remains covered separately.

## 7. Status Text Matrix

Move direct footer formatting assertions for:

- unsynchronized permission mode;
- manual, accept-edits, auto, and plan labels;
- distinct semantic permission highlights;
- model plus thinking at wide width;
- permission priority at narrow width;
- context percentage formatting;
- hidden idle label;
- steering and follow-up queue counts;
- omission of cost/cache details from the persistent footer; and
- exactly one display line within the supplied width.

Use a fresh fake state for each width/priority scenario. Assert that InputArea
reads the display mirror but does not update the authoritative Extension mode.

## 8. Activity and Reasoning Frame

Cover component presentation for:

- idle frame;
- working animation frame and moving highlight;
- generic thinking label in the bottom border only;
- complete reasoning-stage header replacing the generic label;
- incomplete next header not replacing the current complete stage;
- public output clearing the reasoning-stage label;
- error frame and semantic colors; and
- fixed frame width throughout animation.

The test may inject animation-frame values directly into the fake Chat. Timer
start/stop ownership across Chat is covered in Task 15; this test owns only frame
composition from a supplied state.

## 9. Resize, Focus, and Submission

Move and expand cases for:

- empty input retaining minimum padded height;
- multiline input growing to the configured maximum;
- long wrapped input using display width;
- shrinking after content is cleared;
- `set_input` replacing content and placing cursor predictably;
- `focus` selecting the prompt window and insert mode behavior according to the
  current contract;
- Enter preserving embedded newlines in the submitted prompt;
- project root passed with submission;
- prompt cleared only after accepted local submission dispatch; and
- command-menu state closed/reset during submission.

Do not simulate a model response. Stub the public submission callback and assert
the input boundary only.

## 10. Resource Cleanup

Cover:

- `close_windows` closing input/status windows but retaining reusable buffers if
  that is the current contract;
- `destroy` deleting owned buffers and being idempotent;
- cleanup when one window or buffer was already externally closed;
- no callbacks against invalid handles; and
- no InputArea-owned resource remaining after destroy.

Restore every replaced `pi` function even on assertion failure.

## 11. Migration Procedure

1. Create the direct component fixture.
2. Move one behavior cluster from `chat_spec.lua`.
3. Run `input_spec.lua` and `chat_spec.lua` together.
4. Remove the old assertions only after the direct version passes.
5. Leave cross-component alignment and Chat lifecycle assertions for later
   tasks.
6. Run the full Lua suite after each cluster.

## 12. Verification

```bash
make test-file TEST=tests/lua/ui/input_spec.lua
make test-file TEST=tests/lua/ui/chat_spec.lua
make test-file TEST=tests/lua/ui/layout_spec.lua
make test-file TEST=tests/lua/ui/image_chat_spec.lua
make test-lua
make format-check
```

## 13. Risks

- A fake Chat that mirrors private implementation fields too closely can make
  the component test brittle. Expose only documented dependency methods/state.
- Input tests replace public Pi functions. Always restore them through a
  protected cleanup path.
- Enter/feedkeys tests are asynchronous and can leak insert mode. Use bounded
  waits and restore Normal mode before cleanup.
- Keep authoritative permission-mode changes in the Extension; InputArea only
  renders and delegates.

## 14. Completion Checklist

- [ ] `ui/input_spec.lua` exists and runs independently.
- [ ] Prompt buffer isolation and options are covered.
- [ ] Representative keymaps and delegated actions are covered.
- [ ] Frame, footer, resize, focus, and submission behavior is covered.
- [ ] Activity/reasoning presentation is covered without timer ownership drift.
- [ ] Cleanup is idempotent and restores patched globals.
- [ ] Chat retains only cross-component input assertions.
- [ ] Focused tests, full Lua suite, and formatting pass.
