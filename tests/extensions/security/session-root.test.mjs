import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createSessionRootGuard, parseSessionHeader } from "../../../extensions/lib/security/session-root.mjs";

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

test("session header parser and guard reject invalid and cross-project sessions", async () => {
  assert.equal(parseSessionHeader('{"type":"session","version":3,"cwd":"/tmp"}\r').cwd, "/tmp");
  for (const line of ["{", '{}', '{"type":"message","version":3,"cwd":"/tmp"}', '{"type":"session","cwd":"/tmp"}', '{"type":"session","version":3,"cwd":""}']) {
    assert.throws(() => parseSessionHeader(line));
  }
  const base = await mkdtemp(path.join(tmpdir(), "pi-policy-session-"));
  const first = path.join(base, "first");
  const second = path.join(base, "second");
  await mkdir(first);
  await mkdir(second);
  const same = path.join(base, "same.jsonl");
  const other = path.join(base, "other.jsonl");
  await writeFile(same, `${JSON.stringify({ type: "session", version: 3, cwd: first })}\n`);
  await writeFile(other, `${JSON.stringify({ type: "session", version: 3, cwd: second })}\n`);
  const guard = createSessionRootGuard();
  try {
    assert.equal(await guard({ reason: "new" }, context(first)), undefined);
    assert.deepEqual(await guard({ reason: "unknown" }, context(first)), { cancel: true });
    assert.equal(await guard({ reason: "resume", targetSessionFile: same }, context(first)), undefined);
    assert.deepEqual(await guard({ reason: "resume", targetSessionFile: other }, context(first)), { cancel: true });
    assert.deepEqual(await guard({ reason: "resume" }, context(first, { hasUI: false })), { cancel: true });
    const large = path.join(base, "large.jsonl");
    await writeFile(large, `${"x".repeat(65537)}\n`);
    assert.deepEqual(await guard({ reason: "resume", targetSessionFile: large }, context(first)), { cancel: true });
    const thrown = createSessionRootGuard({
      readFirstLine: async () => {
        throw new Error("read failed");
      },
    });
    assert.deepEqual(
      await thrown(
        { reason: "resume", targetSessionFile: same },
        context(first, { ui: { notify: () => { throw new Error("notify failed"); } } }),
      ),
      { cancel: true },
    );
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
