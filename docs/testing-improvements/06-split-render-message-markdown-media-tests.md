# Task 06: Split Renderer Message, Markdown, and Media Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 05
>
> Blocks: Tasks 07 and 08

## 1. Goal

Move assistant/user/status message rendering and Markdown semantics out of the
broad renderer facade spec into focused owner-aligned tests. Clarify the boundary
between inline Markdown/media rendering and the existing image lifecycle tests.

This is a test-only change. It must not redesign transcript text, change
highlights, alter image placement, or make Tree-sitter mandatory.

## 2. Target Test Structure

Create:

```text
tests/lua/ui/render/messages_spec.lua
tests/lua/ui/render/markdown_spec.lua
```

Retain these existing specialized tests:

```text
tests/lua/ui/markdown_image_spec.lua
tests/lua/ui/image_data_spec.lua
tests/lua/ui/image_chat_spec.lua
tests/lua/integration/image_rpc_spec.lua
```

Do not move backend lifecycle or RPC image behavior into renderer specs.

## 3. Ownership Boundaries

| Behavior | Authoritative implementation | Test location |
| --- | --- | --- |
| User/assistant/status components | `lua/pi/ui/render/messages.lua` | `render/messages_spec.lua` |
| Markdown block and inline transformation | `lua/pi/ui/render/markdown.lua` | `render/markdown_spec.lua` |
| Tree-sitter code marks | `lua/pi/ui/render/code.lua` | `render/markdown_spec.lua` with optional parser gate |
| Media descriptors | `lua/pi/ui/render/media.lua` | Focused assertions in `render/markdown_spec.lua` |
| Image decoding, cache, backend placement, lifecycle | image modules | Existing image specs |

Exercise normal transcript composition through `pi.ui.render.render`. Direct
module tests may be used only where a stable pure helper cannot be reached
through the facade without an unrelated fixture.

## 4. Message Spec Cases

Move the message-only portions of the current mixed `items` fixture and add
focused coverage for:

### 4.1 User messages

- text and structural marker rendering;
- absence of legacy role labels;
- multiline input;
- empty input;
- content blocks containing images plus text;
- released-body marker where supplied by the transcript model; and
- semantic `PiUserMessageText` marks.

### 4.2 Assistant messages

- public text with no thinking;
- hidden thinking with duration metadata;
- visible thinking when requested;
- thinking-only messages;
- multiple text blocks;
- stop reason `stop`;
- error stop reason with one-line and CRLF multiline error messages;
- ordering of status metadata before public content; and
- absence of embedded CR/LF inside individual rendered rows.

### 4.3 Status items

- normal and error status text;
- multiline status normalization;
- empty status handling; and
- semantic status/error highlights.

Do not make message tests assert tool group layout or process collapsing; those
belong to Tasks 07 and 08.

## 5. Markdown Spec Cases

Move the current Markdown assertions from `render_spec.lua`, including:

- ATX heading marker removal;
- strong text;
- inline code;
- links displaying labels without leaking targets;
- unordered list markers;
- block quotes;
- fenced Lua code blocks;
- code-surface margins; and
- soft-break versus explicit hard-break behavior.

Add focused cases for:

- paragraphs separated by blank lines;
- nested or adjacent inline tokens;
- unmatched Markdown punctuation;
- empty fenced blocks;
- unknown fence languages;
- common language aliases normalized by `render/code.lua`;
- paths from which a language can be inferred;
- long unbroken words at narrow widths;
- CJK content and UTF-8 byte-column correctness; and
- input containing CRLF.

Avoid asserting a complete transcript snapshot. Assert visible text, ordering,
row widths, and semantic mark spans.

## 6. Tree-sitter Compatibility

Retain the current optional-parser pattern:

1. Probe whether the Lua parser and highlight query are available.
2. Always assert code-block surface and fallback highlight behavior.
3. Assert `@keyword.lua` and other parser-derived groups only when the probe
   succeeds.

The test must pass on Neovim 0.10 installations without a downloaded parser.
Do not fetch parsers during tests.

## 7. Media Boundary Cases

Within `render/markdown_spec.lua`, cover only the structured descriptors the
renderer emits:

- source block identity;
- path or URL preservation where supported;
- row association;
- omission of invalid/unsupported source data; and
- no mutation of input message blocks.

Keep these concerns in existing specialized specs:

- base64 decoding and size limits;
- terminal backend selection;
- external image plugin adapters;
- preview window lifecycle;
- RPC image payload ordering; and
- attachment submission.

## 8. Move Procedure

1. Build minimal message fixtures rather than copying the current combined
   message-plus-three-tools fixture wholesale.
2. Move existing assertions into the relevant focused file.
3. Add owner-specific edge cases.
4. Run each new file through `make test-file`.
5. Delete now-redundant assertions and fixture fields from `render_spec.lua`.
6. Run existing Markdown-image and image integration specs to protect the
   boundary.
7. Run the complete Lua suite.

## 9. Verification

```bash
make test-file TEST=tests/lua/ui/render/messages_spec.lua
make test-file TEST=tests/lua/ui/render/markdown_spec.lua
make test-file TEST=tests/lua/ui/markdown_image_spec.lua
make test-file TEST=tests/lua/integration/image_rpc_spec.lua
make test-file TEST=tests/lua/ui/render_spec.lua
make test-lua
make format-check
```

## 10. Risks

- One mixed fixture currently proves message, Markdown, tools, and semantic marks
  compose together. Preserve one small facade composition case in Task 08.
- Testing exact spaces everywhere creates brittle tests. Use exact spacing only
  where alignment is a product contract.
- Tree-sitter marks use byte columns, while visual width uses display cells.
  Assert them with the correct unit.
- Do not duplicate image lifecycle coverage in renderer tests; duplication makes
  later ownership unclear.

## 11. Completion Checklist

- [ ] Message and Markdown specs exist and run independently.
- [ ] Existing message/Markdown assertions were moved without weakening.
- [ ] Error, CRLF, soft/hard-break, and UTF-8 cases are covered.
- [ ] Tree-sitter remains optional with a deterministic fallback.
- [ ] Renderer media descriptors are covered without absorbing backend tests.
- [ ] Existing image and RPC integration tests still pass.
- [ ] `render_spec.lua` no longer owns detailed message/Markdown cases.
- [ ] Focused tests, `make test-lua`, and `make format-check` pass.
