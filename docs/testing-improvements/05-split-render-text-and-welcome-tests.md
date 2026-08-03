# Task 05: Split Renderer Text and Welcome Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 04
>
> Blocks: Tasks 06 through 08

## 1. Goal

Move text-formatting and welcome-surface assertions out of the broad
`tests/lua/ui/render_spec.lua` file into focused specs owned by the renderer
modules that implement those behaviors.

The move must preserve the public `pi.ui.render` facade contract and add focused
edge coverage for the extracted `pi.ui.render.text` owner. It must not change
production rendering behavior or visual design.

## 2. Target Test Structure

Create:

```text
tests/lua/ui/render/text_spec.lua
tests/lua/ui/render/welcome_spec.lua
```

Retain `tests/lua/ui/render_spec.lua` temporarily for message, tool, process, and
facade composition coverage. Later renderer tasks reduce it further.

The recursive `make test-lua` discovery already supports the new directory.
Verify that fact; do not add a hard-coded file list.

## 3. Ownership Map

| Behavior | Production owner | Focused test owner |
| --- | --- | --- |
| Line splitting and CRLF normalization | `lua/pi/ui/render/text.lua` | `render/text_spec.lua` |
| Tool-result text extraction | `lua/pi/ui/render/text.lua`, exported by facade | `render/text_spec.lua` |
| Duration, elapsed-time, and byte formatting | `lua/pi/ui/render/text.lua` | `render/text_spec.lua` |
| Display-width truncation | `lua/pi/ui/render/text.lua` | `render/text_spec.lua` |
| Welcome content and responsive layout | `lua/pi/ui/render/welcome.lua` | `render/welcome_spec.lua` |
| Public welcome entry | `lua/pi/ui/render.lua` | `render/welcome_spec.lua` through the facade |

Use the private text module directly for owner-specific helpers that are not
part of the public facade. Exercise `render_welcome` through `pi.ui.render` so
the public delegation remains covered.

## 4. Text Spec Work

### 4.1 Move existing duration assertions

Source location at the current baseline:
`tests/lua/ui/render_spec.lua`, the opening duration/elapsed assertions before
the Tree-sitter availability probe.

Move these assertions into `tests/lua/ui/render/text_spec.lua`. Do not copy and
leave duplicates after verification.

Preserve coverage for:

- sub-ten-second elapsed precision;
- minute formatting;
- hour formatting;
- recorded millisecond duration conversion; and
- nil duration behavior where it is part of the current function contract.

### 4.2 Add boundary cases for `split_lines`

Cover:

- nil and empty input;
- one line;
- LF-separated lines;
- CRLF normalization;
- lone CR normalization;
- a trailing newline;
- consecutive empty lines;
- UTF-8 text without code-point corruption; and
- embedded U+2028/U+2029 remaining content rather than becoming JSONL-style
  delimiters.

The renderer helper is not the RPC parser, but retaining these Unicode
characters as content prevents a future generic line-splitting shortcut from
changing valid text.

### 4.3 Add boundary cases for `result_text`

Cover:

- nil result;
- empty content;
- one and multiple text blocks;
- text blocks separated by non-text blocks;
- omitted image markers;
- image-only content; and
- blocks missing optional text.

Assert the input result table is not mutated.

### 4.4 Add formatting boundaries

For duration and elapsed helpers, cover values immediately around:

- zero;
- one second;
- ten seconds;
- sixty seconds;
- one hour; and
- negative or nonnumeric input where the implementation defines normalization.

For byte formatting, cover values around 1 KiB and 1 MiB and verify stable
units. Do not make locale-sensitive assertions.

### 4.5 Add display-width truncation cases

Cover ASCII, CJK, combining or wide characters supported by Neovim's display
width, widths below the ellipsis size, exact fits, and one-cell overflow.

Assert:

- output never exceeds the requested display width;
- a string that fits is returned unchanged;
- truncation does not split a UTF-8 code point; and
- newline-containing input is normalized to one display line before
  truncation.

## 5. Welcome Spec Work

### 5.1 Move existing welcome assertions

Source location at the current baseline:
`tests/lua/ui/render_spec.lua`, the welcome setup and assertions before the Bash
tool fixture is constructed.

Move all existing assertions for:

- title integrated into the border;
- two-column wide layout;
- one-column narrow layout;
- logo and introduction;
- session and workspace sections;
- model, thinking, project, and permission values;
- read-only permission wording;
- removed shortcut/help text;
- exact display width; and
- semantic highlight groups.

### 5.2 Add responsive and content boundaries

Add focused cases for:

- the width immediately below and above the layout breakpoint;
- minimum practical width used by the chat layout;
- a long model name;
- a long project path;
- empty or loading model/thinking values;
- syncing, manual, read-only, plan, and automatic permission labels that the
  renderer supports; and
- CJK or wide characters in user-visible values.

Every rendered line must have a stable display width and must not contain an
embedded CR or LF.

### 5.3 Validate semantic marks structurally

Do not assert only that highlight names occur somewhere. For representative
marks, verify:

- row is within the rendered line array;
- byte columns are non-negative and ordered;
- end column does not exceed the line byte length where the mark is bounded;
- required logo segments are present; and
- removed shortcut highlights are absent.

Avoid a full-line snapshot. Semantic assertions tolerate harmless spacing
refactors while protecting the visible contract.

## 6. Move Procedure

For each cluster:

1. Create the focused spec with a clear success label.
2. Run it through `make test-file`.
3. Remove only the corresponding assertions and now-unused fixture variables
   from `render_spec.lua`.
4. Run both the new spec and the remaining facade spec.
5. Run `make test-lua` before moving to the next cluster.

Do not combine this move with production renderer refactoring or formatting of
unrelated tests.

## 7. Verification

```bash
make test-file TEST=tests/lua/ui/render/text_spec.lua
make test-file TEST=tests/lua/ui/render/welcome_spec.lua
make test-file TEST=tests/lua/ui/render_spec.lua
make test-lua
make format-check
```

Successful behavior:

- both new specs run independently;
- `render_spec.lua` no longer contains text/welcome-only fixtures;
- no existing assertion was silently removed;
- new boundary cases pass on the minimum supported Neovim version in CI; and
- the rendered welcome appearance is unchanged.

## 8. Risks

- Testing private helpers can over-couple tests to implementation. Limit direct
  private-module assertions to stable owner behavior; keep public delegation
  covered through the facade.
- Neovim display width differs from byte length. Use display-width assertions
  for visual constraints and byte offsets only for Extmarks.
- Tree-sitter is irrelevant to the welcome/text task and should not become a
  prerequisite for these specs.
- Do not delete the facade export assertions merely because the helper has a
  direct unit test.

## 9. Completion Checklist

- [ ] `render/text_spec.lua` exists and is independently runnable.
- [ ] `render/welcome_spec.lua` exists and is independently runnable.
- [ ] Existing duration and welcome assertions were moved, not weakened.
- [ ] Text boundary and Unicode cases were added.
- [ ] Welcome responsive and semantic-mark cases were added.
- [ ] `render_spec.lua` no longer owns text/welcome-only behavior.
- [ ] Public `pi.ui.render` delegation remains covered.
- [ ] Focused tests, `make test-lua`, and `make format-check` pass.

