import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createPermissionHandler,
  createWorkspaceGuard,
  isWithinCanonicalRoot,
  resolveLikePi,
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

test("Pi-compatible path normalization covers prefixes, URLs, Unicode spaces, and read variants", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "pi-policy-paths-"));
  const root = path.join(base, "root");
  await mkdir(root);
  const spaced = path.join(root, "space name");
  const nfd = path.join(root, "cafe\u0301.txt");
  const curly = path.join(root, "capture d\u2019ecran.txt");
  const ampm = path.join(root, "capture\u202fPM.png");
  await writeFile(spaced, "x");
  await writeFile(nfd, "x");
  await writeFile(curly, "x");
  await writeFile(ampm, "x");
  const guard = createWorkspaceGuard();
  try {
    assert.equal(resolveLikePi("@space\u00a0name", root), spaced);
    assert.equal(resolveLikePi(`file://${spaced}`, root), spaced);
    assert.equal(resolveLikePi("~/file", root, { homedir: () => base }), path.join(base, "file"));
    for (const requested of ["space\u00a0name", "caf\u00e9.txt", "capture d'ecran.txt", "capture PM.png"]) {
      const call = event("read", { path: requested });
      assert.equal(await guard(call, context(root)), undefined, requested);
    }
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("root containment rejects prefix siblings", () => {
  assert.equal(isWithinCanonicalRoot("/work/app", "/work/app/file"), true);
  assert.equal(isWithinCanonicalRoot("/work/app", "/work/app-other/file"), false);
});

test("confirm mode allows inside reads and confirms outside reads", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "pi-policy-reads-"));
  const root = path.join(base, "root");
  const outside = path.join(base, "outside");
  await mkdir(root);
  await mkdir(outside);
  let confirmations = 0;
  const handler = createPermissionHandler({ select: async () => (++confirmations, "Allow once") });
  try {
    const inside = event("read", { path: "." });
    assert.equal(await handler(inside, context(root)), undefined);
    assert.equal(confirmations, 0);
    const external = event("ls", { path: outside });
    assert.equal(await handler(external, context(root)), undefined);
    assert.equal(confirmations, 1);
    assert.equal(external.input.path, outside);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
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
