# Task 16: Audit Lua Test Failure Reporting and Cleanup

> Status: Proposed. This task has not been implemented.
>
> Parent plan: `docs/focused-test-command.md`
>
> Depends on: Tasks 01 through 15
>
> Blocks: Tasks 17 through 21

## 1. Goal

Audit every Lua spec after decomposition so a failure identifies one focused
behavior and test resources are restored reliably. Improve diagnostics and
cleanup without introducing a test framework or changing runtime behavior.

This task addresses the limitations of top-level `assert` scripts while
retaining their zero-dependency, one-Neovim-process-per-file isolation.

## 2. Scope

Review every recursively discovered file matching:

```text
tests/lua/**/*_spec.lua
```

Pay particular attention to specs that:

- replace `vim.schedule`, `vim.notify`, renderer functions, clipboard adapters,
  or Neovim API functions;
- create timers, jobs, subprocesses, buffers, windows, namespaces, temporary
  files, or image resources;
- enter Insert mode or feed keys;
- wait for asynchronous events;
- alter global configuration/module state; or
- start the fake RPC process.

Do not refactor production code or change assertion expectations in this audit.

## 3. Inventory Procedure

Search for high-risk constructs:

```bash
rg -n 'vim\.wait|vim\.schedule\s*=|vim\.notify\s*=|vim\.api\.[A-Za-z0-9_]+\s*=|new_timer|jobstart|system\(' tests/lua
rg -n 'nvim_create_buf|nvim_open_win|mktemp|tempname|feedkeys|startinsert|stopinsert' tests/lua
rg -n '^assert\(|pcall\(|xpcall\(' tests/lua
```

Build a temporary audit table containing:

- file;
- resource/global being changed;
- current cleanup path;
- whether cleanup runs after assertion failure;
- current failure label;
- required correction; and
- owner task/spec.

The table may live in the implementation record of this task while work is in
progress. Do not add a permanent generated inventory unless it remains useful
after cleanup.

## 4. Failure Message Standard

Every assertion message should answer:

1. Which behavior failed?
2. What stable outcome was expected?
3. When useful, what actual value was observed?

Prefer:

```text
completed process retained 2 hidden tool ranges; expected none
```

Avoid:

```text
failed
wrong value
test 3
```

Rules:

- Use domain language, not implementation line numbers.
- Include IDs/counts/widths only when they aid diagnosis.
- Do not dump full base64 images, model messages, huge tool output, environment
  variables, secrets, or complete RPC frames.
- Preserve security wording such as `fail closed` where it identifies the
  invariant.
- Keep assertions focused; split one assertion that silently checks several
  unrelated outcomes.

## 5. Stable File-Level Reporting

Every Lua spec must end with one stable success label:

```text
<relative-test-name>: ok
```

The exact current convention may remain, but:

- duplicate labels are not allowed;
- a moved spec must update its label to its new owner;
- success must print only after all assertions and cleanup complete; and
- the Make runner's `nvim: <path>` prefix must remain the primary file identity
  on failure.

Do not print a success label from a cleanup handler after a failed assertion.

## 6. Protected Cleanup Pattern

For a spec that replaces globals or owns resources:

1. Create resources and save originals.
2. Run the behavior/assertion body through a protected call.
3. Restore functions/globals first.
4. Stop/close timers and jobs idempotently.
5. Close/delete owned windows and buffers after checking validity.
6. Remove validated task-specific temporary directories.
7. Re-raise the original error with its traceback.
8. Print success only after cleanup and successful body completion.

Do not mask the original assertion with a secondary cleanup error. Collect
cleanup errors and append concise context only when necessary.

Use a local helper inside one spec when only that spec needs it. Extract a shared
test helper only after at least three specs require the same nontrivial cleanup
behavior and the helper can remain stateless.

## 7. Asynchronous Assertion Rules

For every `vim.wait`:

- use a bounded timeout;
- use the smallest polling interval that remains reliable on Neovim 0.10;
- include a diagnostic that describes the awaited state;
- on timeout, print only bounded relevant state;
- never replace a lifecycle assertion with an arbitrary sleep;
- cancel/close the pending resource after timeout; and
- avoid exact elapsed-time expectations on loaded CI hosts.

For scheduled callbacks, assert both that expected work eventually occurs and
that it occurs no more often than the coalescing contract permits.

## 8. Global State and Module Cache

Audit changes to:

- `package.loaded`;
- `vim.g`, `vim.b`, `vim.w`, and options;
- public `pi` functions;
- renderer methods;
- config singleton state;
- autocmd groups;
- highlight groups; and
- current buffer/window/mode.

Because each spec has its own Neovim process, state does not leak between files,
but it can leak between scenarios inside one file and obscure later assertions.
Restore state when a file continues after the changed scenario.

## 9. Focused Review Order

Review in this order so shared/high-risk infrastructure is handled first:

1. `client_spec.lua` and protocol/integration specs.
2. regression performance/output-budget specs.
3. TranscriptView and Chat lifecycle specs.
4. permission, dialog, image preview/backend specs.
5. InputArea and CommandMenu specs.
6. renderer specs.
7. pure config/context/message/format specs.

After each file, run it through `make test-file`. After each category, run
`make test-lua`.

## 10. Verification

Run every Lua spec individually using the same sorted discovery order as the
Makefile, then run:

```bash
make test-lua
make test
make format-check
```

Perform one controlled negative check without committing it:

1. temporarily force one representative assertion to fail;
2. run it through `make test-file`;
3. confirm output names the file and behavior;
4. confirm cleanup still occurs; and
5. restore the temporary change immediately.

Do not leave a deliberately failing fixture or weaken the assertion afterward.

## 11. Risks

- A broad cleanup abstraction can hide resource ownership. Prefer explicit
  cleanup near the fixture.
- Continuing after a failure can make later cases operate on corrupted shared
  state. Protected cleanup should re-raise rather than aggregate unrelated cases
  unless a future harness explicitly isolates them.
- More verbose diagnostics can leak large payloads. Bound actual-value output.
- Formatting-only churn across every spec can obscure behavior changes. Change
  only assertions/cleanup with a documented audit reason.

## 12. Completion Checklist

- [ ] Every Lua spec has a unique stable success label.
- [ ] Every assertion has a behavior-oriented message.
- [ ] Patched globals/functions are restored after success and failure.
- [ ] Timers, jobs, windows, buffers, and temp files have idempotent cleanup.
- [ ] Async waits are bounded and diagnostic.
- [ ] No large/sensitive payload is dumped on failure.
- [ ] Controlled negative verification names the file and behavior.
- [ ] Every focused spec, full Lua suite, full deterministic suite, and format
      check pass.

