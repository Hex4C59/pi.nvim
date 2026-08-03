import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createWorkspaceGuard, workspaceReadOnlyGuidance } from "../../../extensions/lib/security/workspace.mjs";

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

test("workspace guard confines all read tools using canonical paths", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "pi-policy-workspace-"));
  const root = path.join(base, "app");
  const sibling = path.join(base, "app-other");
  await mkdir(path.join(root, "inside"), { recursive: true });
  await mkdir(sibling);
  await writeFile(path.join(root, "inside", "ok.txt"), "ok");
  await writeFile(path.join(sibling, "secret.txt"), "secret");
  await symlink(path.join(root, "inside", "ok.txt"), path.join(root, "inside-link"));
  await symlink(path.join(sibling, "secret.txt"), path.join(root, "outside-link"));
  const guard = createWorkspaceGuard();
  try {
    assert.equal(await guard(event("custom_read", {}), context(root)), undefined);
    assert.equal((await guard(event("read", {}), context(root))).block, true);
    for (const toolName of ["read", "grep", "find", "ls"]) {
      const rootEvent = event(toolName, toolName === "read" ? { path: "." } : {});
      assert.equal(await guard(rootEvent, context(root)), undefined);
      assert.equal(rootEvent.input.path, root);
    }
    for (const requested of [
      "../app-other/secret.txt",
      path.join(sibling, "secret.txt"),
      `file://${path.join(sibling, "secret.txt")}`,
      "~",
      "outside-link",
    ]) {
      const result = await guard(event("read", { path: requested }), context(root));
      assert.equal(result.block, true, requested);
    }
    const inside = event("read", { path: "inside-link" });
    assert.equal(await guard(inside, context(root)), undefined);
    assert.equal(inside.input.path, path.join(root, "inside", "ok.txt"));
    assert.equal((await guard(event("read", { path: "missing" }), context(root))).block, true);
    const find = event("find", { pattern: "../../secret", path: "." });
    assert.equal(await guard(find, context(root)), undefined);
    assert.equal(find.input.pattern, "../../secret");
    assert.equal(find.input.path, root);
    const grep = event("grep", { glob: "../../secret", path: "." });
    assert.equal(await guard(grep, context(root)), undefined);
    assert.equal(grep.input.glob, "../../secret");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("workspace guidance states both tool and canonical-root restrictions", () => {
  assert.match(workspaceReadOnlyGuidance(), /read-only planning mode/);
  assert.match(workspaceReadOnlyGuidance(), /restricted to the canonical current workspace/);
});

test("workspace root cache is keyed by ctx.cwd", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "pi-policy-cache-"));
  const first = path.join(base, "first");
  const second = path.join(base, "second");
  await mkdir(first);
  await mkdir(second);
  const guard = createWorkspaceGuard();
  try {
    assert.equal(await guard(event("ls"), context(first)), undefined);
    assert.equal(await guard(event("ls"), context(second)), undefined);
    assert.equal((await guard(event("ls", { path: first }), context(second))).block, true);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
