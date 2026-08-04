# Bundled Extension Instructions

These instructions apply below `extensions/`. Read the repository root
`AGENTS.md` and `docs/compatibility.md` first. Bundled Extensions execute inside
Pi and own authoritative workflow or tool policy; they are not Neovim modules
and are not an operating-system sandbox.

## Ownership

- Use an Extension when behavior must observe Pi lifecycle or tool events,
  block or mutate a tool call before execution, change the active workflow,
  register an LLM-callable tool, or retain session-owned policy state.
- `permission-gate.ts` owns confirm-mode permission decisions and session
  approvals. `workspace-guard.ts` owns read-only path enforcement.
  `session-root-guard.ts` owns the final same-root session switch invariant.
- Keep entry files small. Put reusable, directly testable behavior in
  `extensions/lib/`, and keep the security policies under
  `extensions/lib/security/` independent as enforced by repository policy.
- State that must follow session restoration or branching uses Pi's documented
  state-management pattern. Do not accidentally persist ephemeral approvals.

## Extension API And UI

- Use `ExtensionAPI` types from `@earendil-works/pi-coding-agent` and inspect the
  matching installed declarations instead of guessing fields.
- In RPC mode, `ctx.mode` is `"rpc"` and `ctx.hasUI` is true. `select`,
  `confirm`, `input`, and `editor` block for a client response. `notify`,
  `setStatus`, `setWidget`, `setTitle`, and `set_editor_text` are
  fire-and-forget.
- TUI-only APIs such as `ctx.ui.custom()` are unavailable or degraded in RPC
  mode. Do not attempt to render Pi TUI components in Neovim.
- Validate every dialog response before changing state or allowing execution.
  Unknown, malformed, cancelled, timed-out, missing-UI, or thrown-error paths
  fail closed for permission-sensitive operations.
- Each dialog request ID is resolved at most once. Pi owns dialog timeouts and
  publishes cancellation; an Extension must not treat client presentation text
  as an authoritative security payload.

## Tool And Lifecycle Policy

- Use `tool_call` for pre-execution blocking or input mutation and `tool_result`
  for result transformation, not permission.
- Canonicalize paths at the execution boundary. Never parse arbitrary shell
  text and claim it is safe.
- Sibling tools may execute in parallel after sequential preflight. Policy must
  remain correct under that ordering.
- Keep unknown tools outside claimed policy coverage unless they explicitly
  register a policy. Plan mode blocks tools outside its declared set.
- Start session-scoped timers, processes, or watchers from `session_start` or on
  demand and clean them idempotently in `session_shutdown`.

## Verification

Changes require authoritative `node:test` coverage under the matching
`tests/extensions/` owner. API loading or RPC UI changes also require
`make smoke`. Lua permission tests cover presentation separately and cannot
replace an Extension policy assertion. See `tests/AGENTS.md` and
`tests/README.md` for the full test matrix.
