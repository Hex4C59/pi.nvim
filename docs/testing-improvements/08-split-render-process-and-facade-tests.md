# Task 08: Split Renderer Process Tests and Retain a Small Facade Spec

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 07
>
> Blocks: Tasks 09 through 21

## 1. Goal

Move completed/active process grouping and disclosure assertions into a focused
process spec, then reduce `tests/lua/ui/render_spec.lua` to a small public-facade
composition test.

This task completes the renderer-spec decomposition. It must preserve public
answer ordering, private-thinking hiding, action counts, semantic ranges, and
responsive behavior.

## 2. Target Structure

Create:

```text
tests/lua/ui/render/process_spec.lua
```

The primary production owner is `lua/pi/ui/render/process.lua`.
`lua/pi/ui/render/engine.lua` owns facade orchestration only.

Retain:

```text
tests/lua/ui/render_spec.lua
```

The retained facade spec should prove that `pi.ui.render` delegates text helper,
welcome, and transcript rendering correctly and that messages, tools, and
processes compose in one result. It must not duplicate every focused assertion.

## 3. Process Behavior to Move

Move the current cases for:

- completed process collapse;
- summary duration and action counts;
- public response before process summary;
- toggle hint and semantic highlights;
- hidden private reasoning and tool details;
- absence of hidden tool ranges;
- one clickable process range;
- staged assistant/tool/assistant sequences;
- active process behavior;
- thinking-only activity;
- expanded process detail; and
- narrow process summary behavior.

Use focused process fixtures instead of sharing mutable item tables with tool or
Markdown tests.

## 4. Required Process Matrix

### 4.1 Completed single-stage process

Cover an assistant item containing thinking and public text followed by one or
more tools. Assert:

- public text remains visible;
- private thinking and detailed tools are hidden in compact mode;
- summary follows the public answer;
- summary counts each supported action category correctly;
- total duration uses the current compact format;
- exactly one process range is emitted; and
- hidden tools emit no clickable ranges.

### 4.2 Completed multi-stage process

Cover assistant update, tool work, and final assistant answer. Assert:

- intermediate public updates retain their intended visibility;
- final public answer is ordered correctly;
- segment boundaries do not merge unrelated user turns;
- summary counts the complete process once; and
- expanding reveals details in original chronological order.

### 4.3 Active process

Cover:

- active thinking before any public output;
- active tools;
- public partial output;
- thinking-only active work;
- completed tools inside a still-active process; and
- transition from active detailed presentation to settled compact summary.

The renderer receives `process_active`; it does not decide agent settlement.
Do not reproduce runtime state transitions here.

### 4.4 Expanded and global tool modes

Verify interaction between:

- `process_expanded`;
- `tools_expanded`;
- per-tool `expanded`; and
- `hide_thinking`.

Assert each option changes only its owned presentation and does not reorder
items or expose stale ranges.

### 4.5 Responsive summaries

At narrow width, assert:

- the disclosure marker remains visible;
- the line stays within display width;
- lower-priority detail is shortened deterministically; and
- counts are not replaced by misleading prose.

## 5. Retained Facade Spec

After focused moves, `tests/lua/ui/render_spec.lua` should contain only a small
composition fixture proving:

1. `pi.ui.render.render_welcome` returns lines and marks.
2. exported text helpers delegate correctly for one representative input.
3. `pi.ui.render.render` accepts a sequence containing a user message,
   assistant public text, and tool item.
4. returned lines, marks, tool ranges, process ranges, and image descriptors keep
   their documented tuple positions.
5. one representative semantic mark from each component survives composition.
6. input item tables are not mutated.

Do not turn the facade spec into a second end-to-end chat test. Buffer writes,
Extmark application, scroll behavior, and user interaction belong to
`TranscriptView` or `Chat` tasks.

## 6. Move and Review Procedure

1. Create `process_spec.lua` with the existing compact/staged/active cases.
2. Run it independently.
3. Remove only those cases from the facade spec.
4. Reduce shared fixtures after all moved assertions are accounted for.
5. Add the small facade composition case.
6. Run every new renderer spec individually.
7. Run the full Lua and deterministic suites.
8. Review the diff specifically for deleted assertion messages.

If an assertion no longer belongs anywhere, document why it was redundant or
obsolete. Do not silently omit it during file movement.

## 7. Verification

```bash
make test-file TEST=tests/lua/ui/render/process_spec.lua
make test-file TEST=tests/lua/ui/render_spec.lua
make test-file TEST=tests/lua/ui/render/text_spec.lua
make test-file TEST=tests/lua/ui/render/welcome_spec.lua
make test-file TEST=tests/lua/ui/render/messages_spec.lua
make test-file TEST=tests/lua/ui/render/markdown_spec.lua
make test-file TEST=tests/lua/ui/render/tools_spec.lua
make test-lua
make test
make format-check
```

## 8. Risks

- Process segmentation depends on item ordering. Simplified fixtures can miss
  boundaries between user turns or staged assistant messages.
- A process summary is presentation, while settlement is authoritative runtime
  state. Keep that ownership distinction explicit.
- Removing the mixed fixture entirely would leave facade composition untested.
- Retaining too much in the facade spec defeats focused execution. Keep only one
  representative cross-module path.

## 9. Completion Checklist

- [ ] `render/process_spec.lua` exists and runs independently.
- [ ] Compact, expanded, staged, active, and narrow process behavior is covered.
- [ ] Public/private ordering and disclosure invariants are preserved.
- [ ] Tool and process ranges are correct in visible and hidden states.
- [ ] `render_spec.lua` is a small facade composition test.
- [ ] Every moved assertion is accounted for.
- [ ] All focused renderer specs pass individually.
- [ ] `make test-lua`, `make test`, and `make format-check` pass.
