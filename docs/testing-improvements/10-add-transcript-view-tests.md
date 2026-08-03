# Task 10: Add Focused Transcript View Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 09
>
> Blocks: Tasks 11 through 15

## 1. Goal

Add direct tests for `pi.ui.transcript_view`, which owns scratch-buffer
projection, render caching, Extmarks, semantic ranges, scroll following, image
placement preparation, and render scheduling.

Move view-level assertions out of Chat where possible while preserving the
existing performance regression as a cross-owner guarantee.

## 2. Target File

Create:

```text
tests/lua/ui/transcript_view_spec.lua
```

Primary owner:

```text
lua/pi/ui/transcript_view.lua
```

The test may create scratch buffers and Neovim windows, but it should construct
`TranscriptView` directly with controlled dependencies instead of constructing a
complete Chat unless the public constructor requires otherwise.

## 3. Controlled Dependencies

Provide deterministic fakes or small callbacks for:

- current window;
- structured items;
- view state;
- retained body bytes;
- pending Bash materialization;
- active-process state;
- widget transcript content;
- permission transcript content;
- image backend capabilities; and
- image-preview preparation callbacks.

Each scenario must own and clean its buffer, window, timers, and fake image
resources. Use a final cleanup path even when an assertion fails after replacing
a Neovim function.

## 4. Required Behavior Matrix

### 4.1 Buffer construction and ownership

Cover:

- lazy scratch-buffer creation;
- buffer name/kind/root metadata;
- nofile, swapfile, modifiable, and filetype options;
- keymaps owned by the transcript surface;
- `owns_buffer` before creation, after creation, and after destroy;
- controlled modifiable sections; and
- idempotent buffer destruction.

The view must not take ownership of prompt, status, permission, widget, or image
preview buffers.

### 4.2 Full render projection

With a small structured item list, assert:

- buffer lines equal renderer output;
- semantic marks are applied in the expected namespace;
- tool/process ranges correspond to rendered rows;
- image descriptors are retained separately from text lines;
- overlay rows are included without mutating source items; and
- projection-byte accounting includes retained lines and mark metadata according
  to the current implementation.

### 4.3 Stable-prefix incremental rendering

Move or factor the direct view portion of
`tests/lua/regression/performance_spec.lua` into focused coverage for:

- completed prefix reuse;
- rendering only the dynamic active tail;
- one partial `nvim_buf_set_lines` write;
- unchanged prefix Extmark IDs surviving;
- dynamic lines not duplicating the complete transcript;
- cache invalidation when an earlier item changes; and
- full fallback render when width or global view state changes.

Keep the regression test's end-to-end Chat performance contract. The focused
view spec should make individual cache rules diagnosable.

### 4.4 Render scheduling and coalescing

Cover:

- multiple schedule requests coalescing into one timer/callback;
- immediate invalidation behavior where supported;
- callback rechecking buffer/window validity;
- scheduled work after destroy becoming a no-op;
- pending flags cleared after completion or cancellation; and
- no full workspace layout triggered by a view-only render.

Use short deterministic waits and always close timers.

### 4.5 Scroll behavior

Cover:

- following new output when the user is at the bottom;
- preserving view when the user has scrolled up;
- clamping blank space below the final transcript row;
- narrow and short windows;
- overlay-height changes; and
- invalid/closed window behavior.

Assert view state, not terminal screenshots.

### 4.6 Hit testing

Cover:

- tool lookup by row;
- process lookup by row;
- image lookup by row;
- image lookup from mouse coordinates;
- boundary rows at first/last inclusive positions;
- no hit in blank/overlay rows; and
- stale ranges removed after collapse or clear.

The view returns structured identities. Chat owns what a click does with them.

### 4.7 Image preparation boundary

Cover only view-owned behavior:

- descriptors sent to the backend in visible order;
- width and row information passed correctly;
- preparation coalescing/cancellation;
- backend unavailable fallback; and
- stale preparation ignored after invalidation or destroy.

Keep decoding, backend adapters, and preview window lifecycle in their existing
specialized specs.

## 5. Migration Rules

Review:

```text
tests/lua/ui/chat_spec.lua
tests/lua/regression/performance_spec.lua
tests/lua/regression/output_budget_spec.lua
tests/lua/ui/image_preview_lifecycle_spec.lua
```

Move only assertions whose authoritative behavior is inside TranscriptView.
Retain:

- Chat action delegation and mouse behavior in Chat specs;
- end-to-end performance and total budget ceilings in regression specs; and
- preview window/resource lifecycle in image preview specs.

Avoid testing `Chat` private forwarding methods when `TranscriptView` can be
constructed directly.

## 6. Verification

```bash
make test-file TEST=tests/lua/ui/transcript_view_spec.lua
make test-file TEST=tests/lua/regression/performance_spec.lua
make test-file TEST=tests/lua/regression/output_budget_spec.lua
make test-file TEST=tests/lua/ui/image_preview_lifecycle_spec.lua
make test-file TEST=tests/lua/ui/chat_spec.lua
make test-lua
make format-check
```

## 7. Risks

- Monkey-patching `vim.api.nvim_buf_set_lines` or the renderer can leak across
  cases. Restore replacements through a protected cleanup path.
- Timing tests can become flaky if they assert exact wall-clock duration. Assert
  coalesced call counts within bounded waits instead.
- Prefix-cache tests must compare semantic output with a full render, not only
  count writes.
- Extmark columns are bytes. Visual line width is display cells.
- Direct view tests must not become a second transcript model by constructing
  items from unstructured RPC events.

## 8. Completion Checklist

- [ ] `ui/transcript_view_spec.lua` exists and runs independently.
- [ ] Buffer lifecycle and ownership are covered.
- [ ] Full and incremental projection are covered.
- [ ] Cache invalidation and render coalescing are covered.
- [ ] Scroll following and clamping are covered.
- [ ] Tool, process, and image hit testing are covered.
- [ ] Image preparation boundaries are covered without duplicating backends.
- [ ] End-to-end performance and budget regressions remain.
- [ ] All created resources and monkey patches are cleaned.
- [ ] Focused tests, full Lua suite, and formatting pass.
