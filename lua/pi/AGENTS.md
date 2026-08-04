# Lua Frontend Instructions

These instructions apply below `lua/pi/`. Read the repository root
`AGENTS.md`, `docs/lua-architecture.md`, and `docs/compatibility.md` first. The
root document owns cross-layer decisions; this file owns Lua implementation
details.

## Layering

- `client.lua` owns subprocess transport, LF-delimited JSONL dispatch, request
  correlation, and raw RPC events. It must not own projected UI state.
- `runtime.lua` owns per-project clients, chats, event projection, capability
  gates, history request state, and frontend action injection.
- `commands/` adapts native actions to runtime/RPC. It must not import Chat UI
  owners or duplicate Pi behavior.
- `ui/chat/` composes the workspace; `ui/transcript/`, `ui/render/`, and
  `ui/image/` own their focused models and views. Keep the dependency direction
  enforced by `scripts/check-lua-architecture.mjs`.
- UI modules receive actions and structured state. They must not import
  `require("pi")` to invoke frontend actions or parse rendered prose to recover
  semantics.

## RPC

- Split records only on LF (`\n`) and strip an optional trailing CR. U+2028 and
  U+2029 are valid JSON string content, not delimiters.
- Add request IDs and correlate responses through `Client.pending`. Commands
  may respond before their asynchronous event stream ends.
- Treat `tool_execution_update.partialResult` as accumulated output unless the
  matching protocol explicitly defines a delta. Direct
  `bash_execution_update.delta` is a delta tied to its originating command ID.
- Correlate tool events by `toolCallId` and Extension dialogs by request ID.
- Use `agent_settled`, not `agent_end`, for the final idle transition.
- Discover Extension commands through `get_commands` and invoke them through
  `prompt`. Never send built-in TUI-only commands blindly as model prompts.
- Gate optional behavior exactly as defined in `docs/compatibility.md`. Missing
  capabilities get the documented fallback or a precise limitation, never a
  version guess or local simulation.

Protocol changes require matching installed documentation/types inspection,
parser or client coverage, a fake-RPC integration when ordering matters, and a
real no-model smoke when installed compatibility changes.

## State And Lifecycle

- Pi owns model, session, message-tree, retry, compaction, queue, and tool state.
  Runtime mirrors it only after authoritative responses or events.
- Runtime owns client-side projection and request generations. Transcript owns
  bounded retained conversation state. Views own Neovim buffers, windows,
  Extmarks, render caches, image placements, and cursor/scroll state.
- Invalidate stale callbacks with owner-specific generations when sessions,
  processes, or projects change. Never let an old response mutate a replacement
  projection.
- Bound decoded queues and retained output before rendering. Visual truncation
  alone does not bound Lua memory.
- Start timers, jobs, and callbacks only when their owner is active. Cleanup
  must be idempotent and cover normal close, buffer deletion, process stop,
  session replacement, and Neovim shutdown.

## UI And Rendering

- Use normal `nofile` buffers and Neovim windows, never a terminal buffer or Pi
  TUI screen scraping.
- Keep renderer input structured and prefer Extmarks for semantic highlights
  and stable anchors.
- Preserve user scroll position unless the view was following output. Coalesce
  streaming redraws and keep optional integrations optional with a text
  fallback.
- `ui/permission.lua` presents permission choices only. It must not infer tool
  kind from titles, parse shell strings, or make allow/block decisions.
- Extension dialog requests receive at most one response. Cancellation returns
  the protocol value; missing UI fails closed for permission-sensitive work.
- `pi.ui.image` is the stable image facade. Do not import its focused private
  owners from unrelated render or transcript modules.
- Compatibility module aliases listed in `docs/compatibility.md` remain
  stateless and must continue to forward to their current owner.

## Verification

Put focused specs under the matching `tests/lua/` owner. Run the closest spec
with `make test-file TEST=...`, then `make test`. Run `make format-check` for Lua
changes and `make smoke` when installed RPC compatibility is affected. See
`tests/AGENTS.md` and `tests/README.md` for the complete test contract.
