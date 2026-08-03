# Task 14: Split Chat Transcript Interaction Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 13
>
> Blocks: Task 15

## 1. Goal

Move Chat-owned user interactions with structured TranscriptView ranges into a
focused spec: per-tool/global expansion, process disclosure, mouse dispatch,
thinking visibility, image-preview dispatch, and copying the last assistant
answer.

TranscriptView owns hit testing; Chat owns what happens after a structured item
is selected. The test must preserve that boundary.

## 2. Target File

Create:

```text
tests/lua/ui/chat/interactions_spec.lua
```

Keep renderer details in renderer specs, model state transitions in
`transcript_spec.lua`, view ranges in `transcript_view_spec.lua`, and image
preview resource behavior in `image_preview_lifecycle_spec.lua`.

## 3. Fixture Design

Create one Chat with a small transcript containing:

- a user message;
- assistant thinking plus public answer;
- one completed multi-line tool;
- one completed process summary;
- one image descriptor where the backend can provide a deterministic fallback;
  and
- enough rows to exercise cursor and mouse boundaries.

Use real renderer/model/view composition for one representative path. For error
branches that are difficult to construct visually, stub only the view lookup
method and return a structured item; do not parse rendered text.

## 4. Tool Interaction Cases

Move existing assertions for:

- global tool expansion and collapse;
- per-tool expansion under cursor;
- per-tool expansion not changing the global flag;
- click on a tool range toggling only that tool;
- expanded output becoming visible;
- collapsed middle output becoming hidden;
- stale/absent range producing no action; and
- click in prompt or unrelated window not being consumed.

Add boundary cases for first/last row of a tool range and an invalid/deleted
window.

The Chat action must use the structured item returned by TranscriptView. It must
not infer tool identity from line text.

## 5. Process Interaction Cases

Move existing assertions for:

- keyboard process toggle;
- click on compact process summary;
- public answer remaining visible in both states;
- private reasoning hidden when compact;
- process details shown when expanded;
- settling from active detail to compact summary; and
- no process action when no process range is selected.

Assert Chat updates its display-only expansion flag, invalidates the view, and
does not alter Pi session messages or settlement state.

## 6. Thinking Visibility

Cover `toggle_thinking` for:

- a transcript containing thinking blocks;
- no thinking content;
- active versus completed process presentation; and
- interaction with `process_expanded`.

The toggle is local presentation. Assert it never changes model thinking level,
Pi core state, or the message content table.

## 7. Mouse Dispatch

Cover dispatch priority and coordinate handling:

1. tool range;
2. process range;
3. image descriptor;
4. blank transcript row; and
5. non-transcript window.

Assert each handled click returns true exactly once and an unhandled click
returns false. Do not let a colorscheme, user mapping, or autocmd affect which
structured item is selected.

## 8. Image Preview Dispatch

Cover only Chat wiring:

- click on a valid image calls ImagePreview with the descriptor;
- opening another image replaces/closes the previous preview through the
  component API;
- unavailable descriptor/backend uses the existing text notification/fallback;
- close action delegates to ImagePreview; and
- Chat does not own preview buffers directly.

Keep actual preview rendering, external backend calls, cancellation, and
resource cleanup in `tests/lua/ui/image_preview_lifecycle_spec.lua`.

## 9. Copy Last Assistant

Cover:

- copying the latest public assistant text;
- skipping thinking-only/private content;
- multiple assistant turns selecting the latest eligible answer;
- no eligible assistant producing the documented notification/no-op;
- multiline text preserved; and
- clipboard adapter failure reported without mutating transcript state.

Stub the clipboard boundary; do not write to the system clipboard in the test.

## 10. Migration Procedure

1. Move interaction assertions from `chat_spec.lua` without copying detailed
   renderer checks.
2. Replace line-text lookup in fixtures with TranscriptView's structured ranges.
3. Run interactions, transcript view, renderer process/tool, and image preview
   specs together.
4. Remove old interaction helpers/fixtures only after all cases pass.
5. Leave close/destroy/activity cleanup for Task 15.

## 11. Verification

```bash
make test-file TEST=tests/lua/ui/chat/interactions_spec.lua
make test-file TEST=tests/lua/ui/transcript_view_spec.lua
make test-file TEST=tests/lua/ui/render/tools_spec.lua
make test-file TEST=tests/lua/ui/render/process_spec.lua
make test-file TEST=tests/lua/ui/image_preview_lifecycle_spec.lua
make test-file TEST=tests/lua/ui/chat_spec.lua
make test-lua
make format-check
```

## 12. Risks

- Parsing rendered lines to identify a tool/process would violate the structured
  UI boundary. Always use view ranges.
- Mouse coordinates are one-based/zero-based in different Neovim APIs. Cover
  range boundaries explicitly.
- Clipboard and image adapters can touch external state. Stub them.
- Local expansion flags must not be mistaken for Pi workflow state.

## 13. Completion Checklist

- [ ] `ui/chat/interactions_spec.lua` exists and runs independently.
- [ ] Global/per-tool/process/thinking toggles are covered.
- [ ] Mouse dispatch uses structured view results.
- [ ] Image preview and clipboard boundaries are stubbed safely.
- [ ] No authoritative Pi state is modified by presentation toggles.
- [ ] Original Chat spec no longer owns detailed interaction cases.
- [ ] Focused interaction/owner tests and full Lua suite pass.
