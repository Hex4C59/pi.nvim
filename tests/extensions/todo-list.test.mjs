import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  createTodoController,
  renderTodoWidget,
  stateFromBranch,
  TodoError,
  todoWorkflowGuidance,
} from "../../extensions/lib/todo-list.mjs";

test("todo keeps sibling permission checks ahead of execution", async () => {
  const source = await readFile(new URL("../../extensions/todo.ts", import.meta.url), "utf8");
  assert.match(source, /executionMode:\s*["']parallel["']/);
  assert.doesNotMatch(source, /executionMode:\s*["']sequential["']/);
});

test("todo controller supports the full lifecycle and keeps one active task", () => {
  const controller = createTodoController();
  assert.equal(controller.execute({ action: "list" }).message, "No todos.");
  assert.equal(controller.execute({ action: "add", text: " Inspect code " }).details.todos[0].text, "Inspect code");
  controller.execute({ action: "add", text: "Implement feature", status: "in_progress" });
  controller.execute({ action: "add", text: "Run tests", status: "in_progress" });
  let state = controller.snapshot();
  assert.deepEqual(state.todos.map((todo) => todo.status), ["pending", "pending", "in_progress"]);

  controller.execute({ action: "update", id: 2, text: "Implement todo Extension", status: "completed" });
  controller.execute({ action: "remove", id: 1 });
  state = controller.snapshot();
  assert.deepEqual(state.todos.map((todo) => [todo.id, todo.text, todo.status]), [
    [2, "Implement todo Extension", "completed"],
    [3, "Run tests", "in_progress"],
  ]);
  assert.match(controller.execute({ action: "list" }).message, /\[x\] #2/);
  assert.equal(controller.execute({ action: "clear" }).details.todos.length, 0);
  assert.deepEqual(controller.snapshot(), { todos: [], nextId: 1 });
});

test("plan atomically decomposes work and advances the active task", () => {
  const controller = createTodoController();
  const created = controller.execute({
    action: "plan",
    tasks: ["Inspect the current behavior", "Implement the change", "Run focused and full verification"],
  });
  assert.match(created.message, /Created plan with 3 tasks/);
  assert.deepEqual(created.details.todos.map((todo) => todo.status), ["in_progress", "pending", "pending"]);

  controller.execute({ action: "update", id: 1, status: "completed" });
  assert.deepEqual(controller.snapshot().todos.map((todo) => todo.status), ["completed", "in_progress", "pending"]);
  controller.execute({ action: "update", id: 2, status: "completed" });
  assert.deepEqual(controller.snapshot().todos.map((todo) => todo.status), ["completed", "completed", "in_progress"]);

  const beforeInvalidPlan = controller.snapshot();
  for (const tasks of [
    ["only one"],
    ["duplicate", "duplicate"],
    Array.from({ length: 13 }, (_, index) => `task ${index}`),
  ]) {
    assert.throws(() => controller.execute({ action: "plan", tasks }), TodoError);
  }
  assert.deepEqual(controller.snapshot(), beforeInvalidPlan, "failed plan replacement must be atomic");
});

test("todo controller rejects malformed and unsafe model input", () => {
  const controller = createTodoController();
  controller.execute({ action: "add", text: "unchanged" });
  for (const params of [
    { action: "add", text: "" },
    { action: "add", text: "x".repeat(501) },
    { action: "add", text: "item", status: "blocked" },
    { action: "update", id: 99, status: "completed" },
    { action: "remove", id: 1.5 },
    { action: "plan" },
    { action: "unknown" },
  ]) {
    assert.throws(() => controller.execute(params), TodoError);
  }
  assert.throws(() => controller.execute({ action: "update", id: 1, text: "must not stick", status: "blocked" }), TodoError);
  assert.equal(controller.snapshot().todos[0].text, "unchanged", "failed updates must be atomic");
});

test("state reconstruction follows the latest valid todo result on the active branch", () => {
  const first = createTodoController();
  const firstDetails = first.execute({ action: "add", text: "first" }).details;
  const secondDetails = first.execute({ action: "add", text: "second" }).details;
  const branch = [
    { type: "message", message: { role: "toolResult", toolName: "todo", details: firstDetails } },
    { type: "message", message: { role: "toolResult", toolName: "read", details: secondDetails } },
    { type: "message", message: { role: "toolResult", toolName: "todo", details: { todos: [] } } },
    { type: "message", message: { role: "toolResult", toolName: "todo", details: secondDetails } },
  ];
  assert.deepEqual(stateFromBranch(branch), {
    todos: [
      { id: 1, text: "first", status: "pending" },
      { id: 2, text: "second", status: "pending" },
    ],
    nextId: 3,
  });

  const restored = createTodoController();
  restored.restore(branch.slice(0, 1));
  assert.equal(restored.execute({ action: "add", text: "branched" }).details.todos[1].id, 2);
});

test("widget rendering is compact, status-marked, ordered, and bounded", () => {
  const lines = renderTodoWidget({
    todos: [
      { id: 1, text: "done", status: "completed" },
      { id: 2, text: "next", status: "pending" },
      { id: 3, text: "now", status: "in_progress" },
    ],
  }, { maxItems: 2 });
  assert.deepEqual(lines, ["Plan · 1/3 complete", "◐ #3 now", "○ #2 next", "… 1 more"]);
  assert.equal(renderTodoWidget({ todos: [] }), undefined);
});

test("workflow guidance requires useful decomposition and continuous status updates", () => {
  const guidance = todoWorkflowGuidance();
  assert.match(guidance, /action "plan" and 3-7 concrete, verifiable tasks/);
  assert.match(guidance, /simple question or a single small change/);
  assert.match(guidance, /unfinished tasks for the same request/);
  assert.match(guidance, /update it to completed immediately/);
  assert.match(guidance, /verification succeeds/);
});
