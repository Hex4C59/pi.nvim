# Task 15: Split Chat Lifecycle Tests and Finalize the Facade Spec

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 14
>
> Blocks: Tasks 16 through 21

## 1. Goal

Move Chat-owned activity, timer, close, destroy, reset, and cross-component
cleanup behavior into a lifecycle spec. Reduce `tests/lua/ui/chat_spec.lua` to a
small facade test that proves the complete Chat workflow composes correctly.

This task completes the large Chat-spec decomposition. It must not remove
integration coverage or duplicate component internals.

## 2. Target Structure

Create:

```text
tests/lua/ui/chat/lifecycle_spec.lua
```

Retain a reduced:

```text
tests/lua/ui/chat_spec.lua
```

The lifecycle spec owns resources and state transitions. The facade spec owns
one representative user-to-assistant-to-tool UI composition path.

## 3. Activity and Animation Lifecycle

Move Chat-level assertions for:

- idle to working starts the frame animation;
- animation frame advances within a bounded wait;
- animation updates InputArea chrome without triggering full workspace layout;
- working to idle stops and closes the timer;
- error state never leaves an active timer;
- repeated working updates do not create duplicate timers;
- close/destroy while working stops the timer; and
- a delayed scheduled callback after destroy is harmless.

InputArea frame text/highlights are already tested in Task 11. Here assert
delegation/call counts and timer ownership rather than every border segment.

## 4. Reasoning-Stage Lifecycle

Cover the Chat/Transcript/InputArea integration for:

- thinking start displays generic activity;
- a complete reasoning header becomes the current stage;
- partial next header does not replace it prematurely;
- complete next header replaces rather than accumulates;
- public text clears the stage from the input frame;
- transient stage text never leaks into transcript lines when thinking is
  hidden; and
- assistant end/abort/clear releases transient state.

Transcript parsing is covered directly in Task 09 and frame presentation in
Task 11. This spec proves the callback path between them.

## 5. Close Versus Destroy

Define and test the distinction:

### `close`

- closes visible Chat/component windows;
- preserves reusable session display state and buffers where currently intended;
- closes image preview windows;
- stops active animation;
- cancels or closes permission UI safely according to its fail-closed adapter
  contract; and
- can be followed by `open` without duplicate buffers or mappings.

### `destroy`

- is safe whether the Chat is open or closed;
- destroys Transcript and TranscriptView resources;
- destroys InputArea, CommandMenu, PermissionPanel, WidgetArea, ImagePreview,
  and image backend resources;
- releases retained bodies, projections, and image references;
- removes the Chat from global instance tracking;
- leaves no valid owned buffer/window/timer; and
- is idempotent.

Do not assert that closing/destroying the Neovim UI deletes Pi's authoritative
session file or messages.

## 6. Clear and Session Display Reset

Cover `Chat:clear` for:

- transcript items/tool indexes reset;
- view ranges/marks/projections invalidated;
- stale widgets and transient reasoning removed where current session semantics
  require it;
- permission mode reset only through its documented display-mirror path;
- welcome restored;
- retained-byte accounting bounded; and
- subsequent user/assistant/tool events render normally.

Keep `/clear` RPC sequencing and session reload in integration tests. This spec
owns local UI reset after the authoritative operation is delivered.

## 7. External Invalidation Cases

Close or delete selected resources out of order and then call `close`/`destroy`:

- main Chat window already closed;
- prompt/status buffer already wiped;
- command menu open;
- permission request visible;
- widget visible;
- image preview open;
- scheduled transcript render pending; and
- image backend cleanup throwing or returning failure according to current
  adapter handling.

Cleanup must be best-effort and idempotent while preserving fail-closed behavior
for pending permission-sensitive requests.

## 8. Reduced Facade Spec

After all moves, `tests/lua/ui/chat_spec.lua` should retain one compact workflow:

1. Construct and open Chat.
2. Confirm prompt focus and all primary components are attached.
3. Submit one multiline user prompt through the input boundary using a stubbed
   public submission callback.
4. Project one assistant public answer with thinking hidden.
5. Project one tool start/update/end.
6. Settle to one compact process summary.
7. Update model/thinking/permission/queue display mirrors.
8. Close and destroy cleanly.

The facade spec should assert representative visible text, component ownership,
and absence of leaked private reasoning. It should not repeat detailed border,
menu, tool-renderer, range, budget, or timer cases.

## 9. Assertion Accounting Review

Before deleting old `chat_spec.lua` sections:

1. Extract every assertion message from the pre-split file.
2. Map it to Task 09, 10, 11, 12, 13, 14, 15, or an existing specialized spec.
3. Mark intentional removals only when behavior is obsolete or duplicated by a
   stronger assertion.
4. Review the mapping in the changeset.

This accounting is required because a large procedural spec can contain hidden
ordering/lifecycle coverage that is easy to lose during a visual split.

## 10. Verification

```bash
make test-file TEST=tests/lua/ui/chat/lifecycle_spec.lua
make test-file TEST=tests/lua/ui/chat/shell_spec.lua
make test-file TEST=tests/lua/ui/chat/interactions_spec.lua
make test-file TEST=tests/lua/ui/chat_spec.lua
make test-file TEST=tests/lua/ui/input_spec.lua
make test-file TEST=tests/lua/ui/command_menu_spec.lua
make test-file TEST=tests/lua/ui/transcript_spec.lua
make test-file TEST=tests/lua/ui/transcript_view_spec.lua
make test-file TEST=tests/lua/ui/permission_spec.lua
make test-file TEST=tests/lua/ui/widget_spec.lua
make test-file TEST=tests/lua/ui/image_preview_lifecycle_spec.lua
make test-file TEST=tests/lua/regression/output_budget_spec.lua
make test-file TEST=tests/lua/regression/performance_spec.lua
make test-file TEST=tests/lua/integration/rpc_ui_spec.lua
make test-lua
make test
make format-check
```

## 11. Risks

- Timers and scheduled callbacks are the highest cleanup risk. Every fixture
  needs a protected teardown path.
- Closing UI is not stopping Pi unless runtime explicitly performs that action;
  keep the test scoped to Chat methods.
- Permission cancellation must remain fail-closed. Do not weaken the Extension
  or UI adapter test to simplify teardown.
- The retained facade test must be small but still protect real composition.
- Concurrent working-tree refactors can move owner methods. Re-read current code
  before executing the task and update only overlapping planned paths.

## 12. Completion Checklist

- [ ] `ui/chat/lifecycle_spec.lua` exists and runs independently.
- [ ] Activity/reasoning timer ownership is covered.
- [ ] Close, reopen, clear, and destroy semantics are distinct and covered.
- [ ] Out-of-order resource invalidation is safe.
- [ ] Permission-sensitive cancellation remains fail-closed.
- [ ] Every old Chat assertion is mapped or intentionally superseded.
- [ ] `chat_spec.lua` is a small composition facade test.
- [ ] All component, regression, integration, full-suite, and formatting checks
      pass.
