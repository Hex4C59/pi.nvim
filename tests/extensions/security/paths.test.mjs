import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  canonicalTarget,
  isWithinCanonicalRoot,
  resolveLikePi,
} from "../../../extensions/lib/security/paths.mjs";

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
  try {
    assert.equal(resolveLikePi("@space\u00a0name", root), spaced);
    assert.equal(resolveLikePi(`file://${spaced}`, root), spaced);
    assert.equal(resolveLikePi("~/file", root, { homedir: () => base }), path.join(base, "file"));
    for (const [requested, expected] of [
      ["space\u00a0name", spaced],
      ["caf\u00e9.txt", nfd],
      ["capture d'ecran.txt", curly],
      ["capture PM.png", ampm],
    ]) {
      assert.equal(await canonicalTarget(requested, root), expected, requested);
    }
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("root containment rejects prefix siblings", () => {
  assert.equal(isWithinCanonicalRoot("/work/app", "/work/app/file"), true);
  assert.equal(isWithinCanonicalRoot("/work/app", "/work/app-other/file"), false);
  assert.throws(() => resolveLikePi(undefined, "/work/app"), /path must be a string/);
});
