# Issue Remediation Record

This document records the defects found during the initial pi.nvim review and
the changes made to resolve them. All seven runtime issues are resolved in the
current working tree.

Review environment:

- Neovim 0.10.4 and 0.12.4
- Pi Coding Agent 0.83.0
- `make test`: passing on both Neovim versions (10 test files)
- `make smoke`: passing on both Neovim versions against the installed Pi
  executable
- `make format-check`: passing
- GitHub Actions matrix: Neovim 0.10.4 and current stable

## Resolution Summary

| ID | Priority | Area | Status | Resolution |
| --- | --- | --- | --- | --- |
| PI-001 | High | Compatibility | Resolved | Added a Neovim 0.10-compatible relative-path fallback |
| PI-002 | High | Extension UI | Resolved | `set_editor_text` now prefills or clears the prompt without submitting |
| PI-003 | Medium | Transcript | Resolved | Extension commands no longer leave stale display entries |
| PI-004 | Medium | Protocol | Resolved | Every complete and trailing RPC frame now observes the byte limit |
| PI-005 | Medium | Bash | Resolved | Streamed output and final truncation metadata are preserved |
| PI-006 | Medium-Low | Buffers | Resolved | Project membership now requires a path boundary |
| PI-007 | Low | Context | Resolved | Context truncation is UTF-8-safe and documented as a byte limit |

## PI-001: Neovim 0.10 Compatibility Failure

**Status:** Resolved

**Implementation:** `lua/pi/context.lua`, `.github/workflows/ci.yml`

### Problem

The README declares Neovim 0.10 as the minimum supported version, but context
path handling called `vim.fs.relpath()`, which is unavailable on Neovim 0.10.
This broke context-producing commands such as `:PiVisual` and `:PiBuffer`.

### Resolution

Relative-path handling now uses `vim.fs.relpath()` when available and otherwise
uses a normalized, project-boundary-aware fallback. Paths inside the project
remain relative; paths outside it remain absolute and unambiguous. CI now runs
the complete test suite on Neovim 0.10.4 and current stable.

### Verification

- `tests/context_spec.lua` temporarily removes `vim.fs.relpath` and verifies the
  fallback for project files, the project root, and outside paths.
- `.github/workflows/ci.yml` defines the supported-version matrix.

## PI-002: `set_editor_text` Sent an Unrequested Prompt

**Status:** Resolved

**Implementation:** `lua/pi/init.lua`, `lua/pi/ui/dialog.lua`

### Problem

Pi RPC defines `set_editor_text` as a fire-and-forget request that updates the
input editor. The old handler routed it through `pi.ask()`, immediately sending
the text to the model. It also ignored an empty string, so extensions could not
clear the editor.

### Resolution

The extension UI handler now receives a prompt-setter callback owned by the
requesting chat. It opens the appropriate chat, calls `Chat:set_input()`, and
focuses the prompt. Both non-empty and empty values are handled, and no `prompt`
RPC request is generated until the user explicitly submits.

### Verification

- `tests/dialog_spec.lua` covers non-empty and empty editor updates as well as
  the other extension dialog cancellation/submission paths.
- `tests/rpc_ui_spec.lua` verifies prefill, clear, focus-path integration, and
  the absence of an unrequested transcript message.

## PI-003: Extension Commands Desynchronized `display_queue`

**Status:** Resolved

**Implementation:** `lua/pi/init.lua`

### Problem

Outgoing display text was stored in a FIFO that assumed every accepted prompt
would emit a user `message_start`. Extension commands can complete without that
event, leaving stale text for the next normal prompt. A failed request also
removed the first FIFO entry rather than its own entry.

### Resolution

The client now caches command metadata returned by `get_commands`. Known
extension commands are not added to the display queue because they do not
produce user messages. Entries that are queued are identity-bearing tables, so
an out-of-order failure removes only the entry belonging to that request.
Prompt templates, skills, `:PiVisual`, and `:PiBuffer` retain their concise
display text.

For an unknown slash command, the renderer falls back to the actual user event
instead of retaining speculative queue state.

### Verification

`tests/rpc_ui_spec.lua` covers:

- an extension no-op followed by a normal prompt;
- prompt-template expansion with concise display text;
- two requests settling out of order, with one rejected.

## PI-004: Oversized Complete RPC Frames Bypassed the Limit

**Status:** Resolved

**Implementation:** `lua/pi/protocol.lua`

### Problem

The parser checked only the unfinished buffer after extracting complete lines.
An oversized newline-terminated frame, or an oversized final frame at EOF,
could therefore reach JSON decoding despite `max_frame_bytes`.

### Resolution

All extracted frames now pass through a shared `_consume()` method. It removes a
trailing carriage return, checks the byte limit, reports and drops oversized
frames, and only then decodes JSON. `Parser:finish()` uses the same path, while a
valid frame after a rejected complete frame remains parseable.

### Verification

`tests/protocol_spec.lua` covers oversized incomplete, newline-terminated, and
EOF frames, plus recovery to a following valid frame.

## PI-005: Complete Bash Output Was Replaced by a Truncated Response

**Status:** Resolved

**Implementation:** `lua/pi/init.lua`, `lua/pi/ui/chat.lua`,
`lua/pi/ui/render.lua`

### Problem

`bash_execution_update` events accumulated complete output, but the final Bash
response replaced it with `data.output`, which Pi may truncate. Synchronous
request-send failures could also occur before `request_id` was assigned and were
silently discarded.

### Resolution

`Chat:end_bash()` now prefers accumulated streamed output and falls back to the
final response only when no stream output exists. Final metadata is retained in
`result.details`; when Pi reports truncation, the expanded tool view displays
`fullOutputPath` when available. A synchronous send failure now produces an
error notification.

### Verification

- `tests/ui_spec.lua` covers streamed/truncated output, non-streamed output,
  metadata retention, and the full-output-path indicator.
- `tests/init_spec.lua` covers a synchronous Bash request failure.

## PI-006: Project Prefix Matching Refreshed Unrelated Buffers

**Status:** Resolved

**Implementation:** `lua/pi/context.lua`, `lua/pi/init.lua`

### Problem

A plain string-prefix check treated paths such as `/tmp/pi-root-other.lua` as
members of the `/tmp/pi-root` project and could refresh unrelated buffers.

### Resolution

The shared `context.is_within_root()` helper normalizes both paths and requires
exact equality or a slash/backslash boundary. Both `refresh_unmodified()` and
`track_buffer()` now use the same membership rule.

### Verification

`tests/context_spec.lua` covers root equality, descendants, sibling-prefix paths,
trailing separators, and normalized paths.

## PI-007: Context Truncation Could Produce Invalid UTF-8

**Status:** Resolved

**Implementation:** `lua/pi/context.lua`, `lua/pi/config.lua`, `README.md`

### Problem

The `max_chars` setting used Lua byte slicing. A cutoff inside a multibyte UTF-8
code point produced invalid text, and the option name incorrectly implied a
character limit.

### Resolution

The public setting is now `context.max_bytes`. Truncation moves a byte cutoff
back to a UTF-8 code-point boundary before appending the truncation notice. The
legacy `max_chars` key remains a compatibility alias and is migrated during
configuration; an explicit `max_bytes` value takes precedence.

### Verification

- `tests/context_spec.lua` covers ASCII, two-byte text, Chinese, emoji, and a
  combining character with cutoffs inside code points.
- `tests/config_spec.lua` covers legacy migration and precedence.

## Test and Maintenance Coverage

The maintenance gaps identified during review are also closed:

- `.github/workflows/ci.yml` runs `make test` on Neovim 0.10.4 and stable and
  runs StyLua as a separate job.
- `tests/dialog_spec.lua` and `tests/rpc_ui_spec.lua` cover extension UI events,
  cancellation, multiline editor submission, and display-queue behavior.
- `tests/protocol_spec.lua` covers every frame-size boundary path.
- `make smoke` keeps real-client validation explicit and separate from the
  deterministic default suite.
- `make format-check` checks `lua`, `plugin`, and `tests`; the current tree is
  formatted and passes the check.

## Verification Commands

```sh
make test
make smoke
make format-check
git diff --check
```

All four commands pass in the review environment listed above. The same Neovim
0.10.4 and stable test matrix is also configured in GitHub Actions.
