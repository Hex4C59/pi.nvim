# Task 07: Split Renderer Tool Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 06
>
> Blocks: Task 08

## 1. Goal

Move detailed tool-row, tool-output, diff, truncation, and hit-range assertions
from `tests/lua/ui/render_spec.lua` into one focused renderer tool spec.

The test owns presentation of already-structured tool items. It must not test or
change actual tool execution, permission decisions, command safety, RPC event
projection, or transcript retention policy.

## 2. Target File

Create:

```text
tests/lua/ui/render/tools_spec.lua
```

The primary production owner is `lua/pi/ui/render/tools.lua`.
`lua/pi/ui/render/engine.lua` orchestrates the focused renderer owners and must
not regain tool-specific formatting logic.

## 3. Existing Coverage to Move

Move the current assertions that cover:

- `Actions` group label;
- connected first and final timeline glyphs;
- edit title and diff statistics;
- deleted and added diff rows;
- Bash title;
- collapsed Bash head/tail preview;
- omitted-line hint;
- read path plus offset;
- collapsed read summary;
- hidden collapsed read body;
- tool semantic highlights; and
- tool row ranges.

Build tool-only fixtures in the new file. Do not retain an assistant Markdown
fixture merely to make the tool tests render.

## 4. Required Tool Matrix

### 4.1 Known built-in tools

Cover representative pending, completed, and failed items for:

- `bash`;
- `read`;
- `write`;
- `edit`;
- `grep`;
- `find`; and
- `ls`.

For each relevant tool verify:

- running versus completed verb;
- subject selection from structured args;
- error verb and error styling;
- duration display where space allows; and
- narrow-width fallback that does not overflow.

### 4.2 Unknown/custom tools

Cover:

- empty args;
- small JSON-serializable args;
- deeply or broadly structured args already bounded by the transcript model;
- JSON encoding failure; and
- a long encoded subject requiring truncation.

The renderer must treat unknown tools as display data. It must not infer
permission or safety semantics from the tool name or serialized args.

### 4.3 Edit and write diffs

Cover:

- one edit using `oldText`/`newText`;
- compatibility forms currently accepted by the renderer;
- multiple edits;
- write content as additions only;
- empty additions/deletions;
- CRLF content;
- UTF-8 diff lines;
- collapsed versus expanded output; and
- correct add/delete counts.

Assert semantic line highlights as well as visible `+` and `-` text.

### 4.4 Output retention presentation

The renderer receives retention metadata from `pi.ui.transcript`; it does not
decide what to release. Cover presentation for:

- completed output below the preview limit;
- completed output above the preview limit;
- pending output retaining its tail;
- failed output retaining its error tail;
- expanded output capped at its renderer safety limit;
- an item whose output was released from local memory;
- client truncation metadata;
- Pi `fullOutputPath`; and
- omitted image/tool-result markers.

Do not reproduce byte-budget algorithms here. Task 09 and the existing output
budget regression own those decisions.

### 4.5 Ranges and semantic marks

For every rendered tool range verify:

- one range per visible tool;
- `first <= last`;
- rows fall within output bounds;
- hidden/collapsed process tools do not expose stale ranges; and
- expanded output updates the range to include visible details.

Verify representative groups for gutter, running/success/failure state, verb,
subject, command, output, omitted rows, and diff surfaces.

## 5. Responsive Behavior

Use at least wide and narrow widths. Assert:

- no rendered line exceeds the requested display width;
- a long command is truncated without splitting UTF-8;
- narrow edit/write headers omit lower-priority duration text if that is the
  current contract;
- path subjects use the current basename fallback only where documented by the
  renderer; and
- status glyphs and the primary tool verb remain visible.

Avoid viewport snapshots. Width, visible priority, and semantic marks are the
stable contract.

## 6. Move Procedure

1. Create small fixture builders local to `tools_spec.lua` only if they make the
   cases easier to read.
2. Move existing assertions before adding new cases.
3. Run the new spec and compare its visible output with the old mixed fixture.
4. Remove tool-only fixture data and assertions from `render_spec.lua`.
5. Keep process-summary tool counts for Task 08; those are process behavior, not
   standalone tool-row behavior.
6. Run the focused and full Lua suites.

## 7. Verification

```bash
make test-file TEST=tests/lua/ui/render/tools_spec.lua
make test-file TEST=tests/lua/ui/render_spec.lua
make test-file TEST=tests/lua/regression/output_budget_spec.lua
make test-lua
make format-check
```

Successful behavior:

- the new spec independently covers all visible tool kinds and states;
- retained/released metadata is rendered but not recalculated;
- the output-budget regression still owns bounded-memory behavior; and
- the facade spec no longer contains detailed tool-row assertions.

## 8. Risks

- Tool input field compatibility is easy to lose while simplifying fixtures.
  Preserve every currently supported path/edit field form before adding new
  cases.
- Do not interpret command strings to decide whether a fixture is safe; no
  command is executed by renderer tests.
- Display-width and byte-column assertions must use different APIs.
- Large output fixtures should be large enough to cross renderer thresholds but
  not allocate tens of megabytes in a presentation test.

## 9. Completion Checklist

- [ ] `render/tools_spec.lua` exists and runs independently.
- [ ] Existing tool assertions were moved, not removed.
- [ ] Known and unknown tools are covered.
- [ ] Pending, completed, failed, released, and truncated states are covered.
- [ ] Diff forms and semantic line highlights are covered.
- [ ] Wide and narrow display behavior is covered.
- [ ] Tool ranges are structurally validated.
- [ ] No tool execution or permission behavior moved into Lua tests.
- [ ] Focused tests, output-budget regression, full Lua suite, and formatting
      pass.
