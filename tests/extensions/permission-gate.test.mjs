import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createPermissionController,
  createPermissionHandler,
  createPermissionToolModeController,
  permissionModeGuidance,
} from "../../extensions/lib/security-policy.mjs";

function event(toolName, input = {}) {
  return { type: "tool_call", toolCallId: Math.random().toString(36), toolName, input };
}

function context(cwd, overrides = {}) {
  return {
    cwd,
    hasUI: true,
    ui: {
      select: async () => "Allow once",
      setStatus: () => {},
      notify: () => {},
    },
    ...overrides,
  };
}

test("manual mode asks for every model command and mutation", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "pi-policy-confirm-"));
  const calls = [];
  const controller = createPermissionController({ select: async (...args) => (calls.push(args), "Allow once") });
  try {
    await writeFile(path.join(root, "a"), "old");
    for (const command of [
      "printf hello",
      "rm -f -r /tmp/demo",
      "git -C . reset --hard",
      "find . -delete",
      'python3 -c "import shutil; shutil.rmtree(\"src\")"',
    ]) {
      assert.equal(await controller.onToolCall(event("bash", { command }), context(root)), undefined);
    }
    assert.equal(await controller.onToolCall(event("edit", { file_path: "a", edits: [] }), context(root)), undefined);
    assert.equal(await controller.onToolCall(event("write", { path: "b", content: "hello" }), context(root)), undefined);
    assert.equal(calls.length, 7);
    assert.deepEqual(calls[0][1], ["Block", "Allow once", "Allow for session"]);
    assert.match(calls[0][0], /^Bash command\nprintf hello/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("permission requests fail closed for UI failures and malformed inputs", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "pi-policy-fail-"));
  try {
    const command = event("bash", { command: "printf hello" });
    assert.equal((await createPermissionHandler({ select: async () => "Block" })(command, context(root))).block, true);
    assert.equal((await createPermissionHandler()(command, context(root, { hasUI: false }))).block, true);
    assert.equal(
      (await createPermissionHandler({ select: async () => Promise.reject(new Error("rejected")) })(command, context(root)))
        .block,
      true,
    );
    assert.equal(
      (await createPermissionHandler({ select: () => { throw new Error("thrown"); } })(command, context(root))).block,
      true,
    );
    const timeout = createPermissionHandler({
      select: () => new Promise(() => {}),
      timeoutMs: 1,
      setTimeout: (callback) => (callback(), 1),
      clearTimeout: () => {},
    });
    assert.equal((await timeout(command, context(root))).block, true);
    let timerStarted = false;
    const noImplicitTimeout = createPermissionHandler({
      select: async () => "Block",
      setTimeout: () => {
        timerStarted = true;
      },
    });
    assert.equal((await noImplicitTimeout(command, context(root))).block, true);
    assert.equal(timerStarted, false, "permission prompts must wait for an explicit response by default");
    assert.equal((await createPermissionHandler({ select: async () => undefined })(command, context(root))).block, true);
    assert.equal((await createPermissionHandler({ select: async () => "Always" })(command, context(root))).block, true);
    assert.equal((await createPermissionHandler()(event("bash", {}), context(root))).block, true);
    assert.equal((await createPermissionHandler()(event("write", { path: "x" }), context(root))).block, true);
    assert.equal(
      (await createPermissionHandler()(event("edit", { path: "missing", edits: [] }), context(root))).block,
      true,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a pending permission request gates later tool calls", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "pi-policy-gate-"));
  let resolveChoice;
  let selectionStarted = false;
  let laterSettled = false;
  const controller = createPermissionController({
    select: () => new Promise((resolve) => {
      selectionStarted = true;
      resolveChoice = resolve;
    }),
  });
  try {
    const pending = controller.onToolCall(event("bash", { command: "git status" }), context(root));
    while (!selectionStarted) await new Promise((resolve) => setImmediate(resolve));
    const later = controller.onToolCall(event("todo", { action: "list" }), context(root)).then((result) => {
      laterSettled = true;
      return result;
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(laterSettled, false, "a later safe tool bypassed the unresolved permission request");

    resolveChoice("Block");
    assert.equal((await pending).block, true);
    assert.equal(await later, undefined);
    assert.equal(laterSettled, true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("parallel Allow once decisions remain independent", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "pi-policy-parallel-"));
  let calls = 0;
  const handler = createPermissionHandler({ select: async () => (++calls === 1 ? "Allow once" : "Block") });
  try {
    const results = await Promise.all([
      handler(event("bash", { command: "first" }), context(root)),
      handler(event("bash", { command: "second" }), context(root)),
    ]);
    assert.equal(calls, 2);
    assert.equal(results.filter((result) => result?.block).length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("permission modes have distinct boundaries and session approvals use strict scopes", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "pi-policy-modes-"));
  const root = path.join(base, "root");
  const outside = path.join(base, "outside");
  await mkdir(root);
  await mkdir(outside);
  await writeFile(path.join(root, "edit.txt"), "old");
  const choices = [];
  const controller = createPermissionController({
    select: async () => choices.shift() ?? "Block",
  });
  try {
    await controller.setMode("acceptEdits");
    assert.equal(await controller.onToolCall(event("edit", { path: "edit.txt", edits: [] }), context(root)), undefined);
    assert.equal(await controller.onToolCall(event("write", { path: "new.txt", content: "new" }), context(root)), undefined);
    choices.push("Allow once");
    assert.equal(await controller.onToolCall(event("bash", { command: "git status" }), context(root)), undefined);
    choices.push("Block");
    assert.equal((await controller.onToolCall(event("write", { path: path.join(outside, "x"), content: "x" }), context(root))).block, true);

    await controller.setMode("auto");
    assert.equal(await controller.onToolCall(event("read", { path: "." }), context(root)), undefined);
    assert.equal(await controller.onToolCall(event("write", { path: "auto.txt", content: "x" }), context(root)), undefined);
    assert.equal(await controller.onToolCall(event("bash", { command: "git status" }), context(root)), undefined);
    assert.equal(
      await controller.onToolCall(
        event("bash", { command: "git diff" }),
        context(root, { hasUI: false, ui: undefined }),
      ),
      undefined,
    );
    const outsideWrite = event("write", { path: path.join(outside, "auto.txt"), content: "x" });
    assert.equal(await controller.onToolCall(outsideWrite, context(root)), undefined);
    assert.equal(outsideWrite.input.path, path.join(outside, "auto.txt"));
    const outsideRead = event("read", { path: outside });
    assert.equal(await controller.onToolCall(outsideRead, context(root)), undefined);
    assert.equal(outsideRead.input.path, outside);
    assert.equal(choices.length, 0, "auto mode must not open the permission UI");
    assert.equal((await controller.onToolCall(event("bash", {}), context(root))).block, true);

    await controller.setMode("plan");
    assert.equal((await controller.onToolCall(event("bash", { command: "git status" }), context(root))).block, true);
    assert.equal((await controller.onToolCall(event("edit", { path: "edit.txt", edits: [] }), context(root))).block, true);
    assert.equal(await controller.onToolCall(event("ls", { path: "." }), context(root)), undefined);
    assert.equal(await controller.onToolCall(event("todo", { action: "list" }), context(root)), undefined);
    assert.equal((await controller.onToolCall(event("custom_mutation", {}), context(root))).block, true);

    await controller.setMode("manual");
    choices.push("Allow for session");
    assert.equal(await controller.onToolCall(event("bash", { command: "git diff" }), context(root)), undefined);
    assert.equal(controller.approvalCount(), 1);
    assert.equal(await controller.onToolCall(event("bash", { command: "git diff" }), context(root)), undefined);
    choices.push("Block");
    assert.equal((await controller.onToolCall(event("bash", { command: "git push" }), context(root))).block, true);
    await controller.setMode("auto");
    assert.equal(controller.approvalCount(), 0, "mode changes must clear approvals");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("permission mode guidance tells the model the exact current boundary", async () => {
  const controller = createPermissionController();
  for (const [mode, expected] of [
    ["manual", "require user confirmation"],
    ["acceptEdits", "inside the current workspace proceed without confirmation"],
    ["auto", "proceed without confirmation"],
    ["plan", "read-only planning mode"],
  ]) {
    await controller.setMode(mode);
    const result = controller.onBeforeAgentStart({ systemPrompt: "base prompt" });
    assert.match(result.systemPrompt, /^base prompt/);
    assert.match(result.systemPrompt, new RegExp(expected));
  }
  assert.match(permissionModeGuidance("plan"), /Do not run Bash commands/);
});

test("plan mode exposes only safe tools and restores the exact previous tool set", () => {
  let active = ["read", "bash", "edit", "write", "todo", "custom_mutation"];
  const changes = [];
  const tools = createPermissionToolModeController({
    getActiveTools: () => active,
    setActiveTools: (next) => {
      active = [...next];
      changes.push([...next]);
    },
  });

  tools.onModeChange("plan", "manual");
  assert.deepEqual(active, ["read", "todo"]);
  assert.deepEqual(tools.snapshot(), ["read", "bash", "edit", "write", "todo", "custom_mutation"]);

  active.push("custom_late_tool");
  tools.enforce("plan");
  assert.deepEqual(active, ["read", "todo"]);

  tools.onModeChange("acceptEdits", "plan");
  assert.deepEqual(active, ["read", "bash", "edit", "write", "todo", "custom_mutation"]);
  assert.equal(tools.snapshot(), undefined);
  assert.equal(changes.length, 3);
});

test("failed tool-set transitions leave the authoritative permission mode unchanged", async () => {
  const notifications = [];
  const controller = createPermissionController({
    onModeChange: () => {
      throw new Error("tool switch failed");
    },
  });
  const ctx = context("/tmp", {
    ui: {
      select: async () => "plan",
      setStatus: () => {},
      notify: (message, level) => notifications.push([message, level]),
    },
  });
  await controller.command("plan", ctx);
  assert.equal(controller.getMode(), "manual");
  assert.match(notifications.at(-1)[0], /tool switch failed/);
  assert.equal(notifications.at(-1)[1], "error");
});

test("failed Plan restoration keeps the reported mode aligned with the restricted tools", async () => {
  const statuses = [];
  const notifications = [];
  const controller = createPermissionController({
    onModeChange: (next, previous) => {
      if (previous === "plan" && next === "manual") throw new Error("restore failed");
    },
  });
  const ctx = context("/tmp", {
    ui: {
      select: async () => "manual",
      setStatus: (key, value) => statuses.push([key, value]),
      notify: (message, level) => notifications.push([message, level]),
    },
  });
  await controller.setMode("plan", ctx);
  await controller.onSessionStart({ reason: "new" }, ctx);
  assert.equal(controller.getMode(), "plan");
  assert.deepEqual(statuses.at(-1), ["pi.permission_mode", "plan"]);
  assert.match(notifications.at(-1)[0], /remaining in plan/);
  assert.equal(notifications.at(-1)[1], "warning");
});

test("session lifecycle and permission command publish authoritative mode", async () => {
  const statuses = [];
  const notifications = [];
  const ctx = context("/tmp", {
    ui: {
      select: async () => "auto",
      setStatus: (key, value) => statuses.push([key, value]),
      notify: (message, level) => notifications.push([message, level]),
    },
  });
  const controller = createPermissionController();
  await controller.onSessionStart({ reason: "startup" }, ctx);
  assert.equal(controller.getMode(), "manual");
  assert.deepEqual(statuses.at(-1), ["pi.permission_mode", "manual"]);
  await controller.command("accept-edits", ctx);
  assert.equal(controller.getMode(), "acceptEdits");
  assert.deepEqual(statuses.at(-1), ["pi.permission_mode", "acceptEdits"]);
  await controller.command("", ctx);
  assert.equal(controller.getMode(), "auto");
  await controller.command("unsafe", ctx);
  assert.equal(controller.getMode(), "auto");
  assert.equal(notifications.at(-1)[1], "error");
  await controller.onSessionStart({ reason: "new" }, ctx);
  assert.equal(controller.getMode(), "manual");
});
