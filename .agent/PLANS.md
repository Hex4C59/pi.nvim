# ExecPlan Guide

An ExecPlan is a checked-in, living implementation record for work that cannot
be completed reliably from one short conversation. It lets another developer or
agent resume from the repository and the plan without relying on hidden context.

Use an ExecPlan when at least one of these conditions applies:

- the work is expected to span multiple sessions or distinct implementation
  milestones;
- the authoritative change spans both the Pi and pi.nvim repositories;
- a prototype or source investigation must resolve an important design unknown;
- RPC, security, persisted state, or public compatibility work is broad enough
  that decisions and evidence will evolve during implementation;
- the user explicitly requests an ExecPlan or durable implementation spec.

Do not create one for an ordinary local fix, a small refactor, or a change that
can remain decision-complete in the active task. The root [development
guide](../AGENTS.md) still requires a conversational implementation plan for
some high-risk changes even when a checked-in ExecPlan would add no value.

## Location And Lifecycle

Create exactly one active plan at `.agent/plans/<kebab-case-task>.md`. For work
across Pi and pi.nvim, keep the plan in the repository where the user started
the task and reference the other checkout explicitly. Do not maintain duplicate
plans whose decisions can drift.

During planning, inspect discoverable repository and dependency facts before
asking questions. The plan must resolve implementation choices, ownership,
interfaces, failure behavior, compatibility, and acceptance criteria before
substantive edits begin. Record a genuine unknown as an investigation milestone
with an observable decision gate rather than guessing.

During implementation, treat the plan as mutable state:

- update `Progress` whenever a milestone starts, completes, or is blocked;
- record unexpected facts and the evidence that established them;
- record each material decision when it is made, including its rationale;
- revise later sections when discoveries invalidate an earlier assumption;
- list exact verification commands and their results;
- keep the document sufficient for a new contributor who has only the plan and
  the repository tree.

Do not stop at a milestone merely to ask for the next instruction when the plan
already authorizes the next safe action. If the work needs new authority or a
product decision not supplied by the user, record the blocker and ask for that
specific input.

At completion, resolve every progress item and write the outcome and remaining
risks. Transfer durable facts into code, tests, README, the [compatibility
contract](../docs/compatibility.md), or an applicable architecture document.
Then remove the active plan in the same change; Git history retains the
plan only if it was committed during implementation. Shipped behavior and its
durable documentation remain the final record; `.agent/plans/` is not a
completed-plan archive.

## Required Form

Every active plan must:

- use a lowercase kebab-case filename ending in `.md`;
- begin with one level-one title followed by the exact line `Status: active`;
- contain each required level-two section below exactly once and in order;
- keep every section meaningful and current rather than leaving template
  instructions in place;
- use dated checkboxes in `Progress`, with `YYYY-MM-DD` or a UTC timestamp;
- describe acceptance as observable behavior and executable commands;
- remain below 256 KiB so it stays practical agent context.

Run `node scripts/check-exec-plans.mjs` after changing this guide or an active
plan. Repository policy tests also run the checker through `make test`.

## Template

Copy this structure into `.agent/plans/<kebab-case-task>.md` and replace every
instructional placeholder before relying on it:

```markdown
# <Outcome-oriented title>

Status: active

## Purpose

State the user-visible outcome, why it matters, and the boundary of the work.

## Progress

- [ ] 2026-08-04T00:00:00Z - Describe the current milestone.

## Surprises And Discoveries

- Observation: Record an unexpected fact, or state that none are known yet.
  Evidence: Name the command, source location, or test that established it.

## Decision Log

- Decision: State a material implementation choice.
  Rationale: Explain ownership and tradeoffs.
  Date: 2026-08-04

## Context And Orientation

Describe the relevant files, existing behavior, terminology, owners, and the
starting repository state. Do not assume the reader saw the original chat.

## Implementation Plan

Describe milestones in execution order, including concrete locations, control
or data flow, failure and cleanup behavior, and the state after each milestone.

## Validation And Acceptance

List exact commands and the observable behavior that constitutes acceptance.
Include focused checks and the scope-appropriate completion gates.

## Recovery And Idempotence

Explain which steps are repeatable, how partial work is detected, and how to
recover without discarding unrelated changes or corrupting external state.

## Interfaces And Dependencies

Name the interfaces, types, commands, versions, external repositories, and
authoritative state owners the finished change depends on.

## Outcomes And Retrospective

While work is active, state what remains to be evaluated. Before closeout,
summarize delivered behavior, verification evidence, deviations, and residual
risks.
```
