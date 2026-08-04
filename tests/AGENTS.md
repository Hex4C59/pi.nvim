# Test Instructions

These instructions apply below `tests/`. Read the repository root `AGENTS.md`
and `tests/README.md` first. Tests are organized by authoritative behavior
owner, not merely by the file that happened to change.

## Determinism And Ownership

- Default tests must not call a model, require authentication, use paid tokens,
  install packages, or fetch network resources.
- Put Lua specs under `tests/lua/` with a recursively discoverable
  `*_spec.lua` name. Put Extension tests under `tests/extensions/` with a
  recursively discoverable `*.test.mjs` name. Repository contracts belong in
  `tests/policy/*_test.sh`, including ExecPlan structure and lifecycle rules.
- Keep transport, event projection, rendering, UI composition, and Extension
  policy assertions at their owning layers. Security changes need an
  authoritative Extension assertion plus a separate Lua UI assertion when
  presentation also changes.
- Use structured fixtures and events. Do not parse rendered prose to recover
  security, session, queue, tool, or image semantics.
- The fake RPC process is deterministic integration infrastructure. Installed
  Pi behavior belongs in `tests/smoke/` and must remain no-model.

## Lua Specs

- Keep each file independently runnable in a fresh headless Neovim process and
  end with one unique, stable `<owner>_spec: ok` label after cleanup succeeds.
- Give assertions behavior-oriented diagnostics and bound asynchronous waits by
  the named state being awaited. Arbitrary sleeps are not lifecycle assertions.
- Never dump full RPC frames, Base64 images, large tool output, prompt content,
  environment variables, credentials, or other secrets in failures.
- Save and restore patched globals and functions. For resource-owning specs,
  protect the body with `xpcall(..., debug.traceback)`, restore globals first,
  then stop jobs/timers, close windows, delete buffers, and remove only
  validated temporary paths before re-raising the original traceback.
- Keep cleanup helpers beside the fixture they own. The suite intentionally has
  no shared mutable Lua harness.

## Commands

- Focused loop: `make test-file TEST=<repository-relative-test-path>`.
- Complete deterministic gate: `make test`.
- Lua formatting: `make format-check`.
- Installed no-model compatibility: `make smoke`.
- GitHub Actions pin policy: `make ci-policy-check`.
- Focused ExecPlan policy: `node scripts/check-exec-plans.mjs`.
- Diagnostic coverage, never a correctness replacement: `make coverage`.

Run the owner-focused test while editing and the complete scope-appropriate
gate before completion. Do not weaken an authoritative test to make a client
adapter test pass.
