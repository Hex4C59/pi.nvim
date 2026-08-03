# Task 09: Add Focused Transcript Model Tests

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`. Current module ownership is
> documented in `docs/lua-architecture.md`.
>
> Depends on: Tasks 01 through 08
>
> Blocks: Tasks 10 through 15

## 1. Goal

Add direct tests for `pi.ui.transcript`, the bounded in-memory display model that
projects Pi messages and tool events into structured renderer items.

Move model-level assertions out of Chat and broad regression fixtures where
appropriate, while retaining regression tests that protect cross-owner memory
budgets. This task must not move authoritative session state from Pi into Lua.

## 2. Target File

Extend the initial focused file already present in the current working tree:

```text
tests/lua/ui/transcript_spec.lua
```

Primary production owner:

```text
lua/pi/ui/transcript.lua
```

The current spec already covers representative Bash bounds, generic partial
replacement, shared tool budget, eviction order, image omission, history
correlation, and tolerant unknown events. This task must preserve those cases
and add the missing user/assistant/image ownership/clear/destroy boundaries
listed below; it must not recreate or overwrite the existing file.

Keep these broader tests:

- `tests/lua/regression/output_budget_spec.lua` for end-to-end retained-memory
  ceilings across Transcript, TranscriptView, and Chat;
- `tests/lua/integration/rpc_ui_spec.lua` for fake RPC event ordering; and
- Chat facade tests for delegation and UI interaction.

## 3. Test Fixture Design

Construct `Transcript` directly with explicit injected dependencies matching its
public constructor contract. Record:

- change notifications and whether they request immediate rendering;
- invalidated item identities;
- image tracking/release callbacks;
- configured output budgets; and
- localized image descriptors.

The focused model spec should not create Neovim windows. A scratch buffer is
acceptable only if a Neovim API used by the model requires it; no transcript
projection should be rendered here.

Each independent scenario should build a fresh Transcript to prevent body-byte,
tool-ID, or streaming-assistant state from leaking between cases.

## 4. Required Behavior Matrix

### 4.1 User projection

Cover:

- text-only user input;
- structured content blocks;
- image-only and text-plus-image content;
- attachment count and size validation;
- localization without mutating the caller's blocks;
- body-byte accounting;
- truncation markers; and
- clearing/releasing image ownership.

Assert the transcript is a bounded display copy, not the authoritative Pi
message table.

### 4.2 Assistant lifecycle

Cover:

- `start_assistant`;
- repeated `update_assistant` calls;
- thinking start and delta events;
- extraction of a complete reasoning-stage header;
- incomplete next header not replacing the active label;
- public text clearing the transient reasoning status;
- `end_assistant` with stop, error, and empty content;
- invalidation callbacks; and
- no mutation of the input message.

Assert streaming state points to exactly one current assistant and is released
when the message ends.

### 4.3 Generic tool lifecycle

Cover:

- start, partial update, and end;
- lookup by tool-call ID;
- duplicate or unknown update/end IDs according to the current contract;
- pending versus completed state;
- error propagation;
- structured result content;
- argument bounding and node limits;
- shared per-tool argument/result budget; and
- release of old completed bodies before newer bodies.

Unknown tool names must remain structured items without inferred policy.

### 4.4 Bash streaming lifecycle

Cover:

- multiple deltas appended in order;
- line and byte limits;
- chunk-count limits;
- final output with no deltas;
- streamed output taking precedence over a truncated final echo;
- exit code and error state;
- client truncation counters;
- Pi truncation metadata and `fullOutputPath`;
- materializing a pending Bash buffer before render; and
- release on clear/destroy.

The model accumulates documented delta events. Renderer tests must not repeat
this algorithm.

### 4.5 History projection

Cover representative persisted history containing:

- user messages;
- assistant text and thinking;
- assistant tool calls;
- matching tool results;
- unmatched or malformed tool results according to current behavior;
- image blocks;
- error messages; and
- multiple turns.

Assert:

- chronological order is preserved;
- tool results correlate by ID;
- the caller's history array is unchanged;
- localized images do not retain source base64 in the display model; and
- newest bodies are retained ahead of older releasable bodies.

### 4.6 Transcript-wide budget

Directly cover deterministic model decisions:

- non-tool and tool retained-byte counters;
- oldest eligible body released first;
- pending tools protected where required;
- arguments and results both included;
- release markers retain lightweight identity/status metadata;
- clear resets counters and indexes; and
- destroy is idempotent.

Keep only cross-layer accounting and renderer-marker assertions in
`output_budget_spec.lua`.

## 5. Migration from Existing Tests

Review these files for model-level assertions:

```text
tests/lua/ui/chat_spec.lua
tests/lua/regression/output_budget_spec.lua
tests/lua/ui/image_chat_spec.lua
```

Move an assertion only when it can be expressed against `Transcript` without a
window, rendered line, Extmark, or Chat interaction. Do not remove:

- end-to-end total-byte accounting from the regression test;
- rendered release markers from renderer/regression coverage;
- attachment UI behavior from image/chat tests; or
- RPC sequencing from integration tests.

During migration, run the source and destination specs before deleting the old
copy.

## 6. Verification

```bash
make test-file TEST=tests/lua/ui/transcript_spec.lua
make test-file TEST=tests/lua/regression/output_budget_spec.lua
make test-file TEST=tests/lua/ui/image_chat_spec.lua
make test-file TEST=tests/lua/integration/rpc_ui_spec.lua
make test-lua
make format-check
```

Successful behavior:

- the model spec needs no chat window;
- all state transitions and counters are deterministic;
- authoritative caller messages remain unchanged;
- broader regression and integration coverage remains intact; and
- no budget is weakened to make the move pass.

## 7. Risks

- Direct tests can accidentally depend on private fields. Assert public
  behavior and documented accounting fields; use private state only where it is
  the current explicit model contract.
- Image localization can allocate filesystem cache entries. Inject or clean all
  resources deterministically.
- Very large fixtures can make the focused test slow. Cross thresholds with
  small configured limits rather than multi-megabyte defaults.
- Do not claim local body release changes Pi's authoritative session or context.

## 8. Completion Checklist

- [ ] `ui/transcript_spec.lua` exists and runs independently.
- [ ] User, assistant, generic tool, Bash, and history lifecycles are covered.
- [ ] Byte/count budgets and release order are covered directly.
- [ ] Image ownership and cleanup are deterministic.
- [ ] Input messages and history are not mutated.
- [ ] Cross-layer output-budget and RPC integration coverage remains.
- [ ] Chat no longer owns model-only assertions.
- [ ] Focused tests, full Lua suite, and formatting pass.
