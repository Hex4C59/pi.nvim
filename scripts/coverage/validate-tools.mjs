import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [nodeMajor, nodeMinor] = process.versions.node.split(".").map(Number);

if (nodeMajor < 20 || (nodeMajor === 20 && nodeMinor < 1)) {
  throw new Error(
    `coverage requires Node >=20.1; found ${process.versions.node}`,
  );
}

const coverageDir = dirname(fileURLToPath(import.meta.url));
const vendorRoot = join(coverageDir, "..", "vendor", "luacov");
const expectedFiles = new Map([
  [
    "LICENSE",
    "70e16311956ccee45fa61973c5a00cd049d7a770ae07b16bbe49e17e6c99ee3d",
  ],
  [
    "luacov.lua",
    "11243da09d66230c236dab427f45871893086e56c5e83b5734d7a825055d4d00",
  ],
  [
    "luacov/defaults.lua",
    "7bc137242f370141f827c74749e06c141747a91f5d1b8a790aaafae185836142",
  ],
  [
    "luacov/hook.lua",
    "b740112f32792a09a98b0c6a7f22db1ff401fc9abef3f76b8b0adcc658af2a5e",
  ],
  [
    "luacov/linescanner.lua",
    "acb3ab4f4b073a810f58491259df5c38799a0e2c8fc4a0f121c6323ba2115959",
  ],
  [
    "luacov/reporter.lua",
    "08be9aa58cac1cfd624accbcdc35488b2423f513fafe06662a55eb9cde879400",
  ],
  [
    "luacov/runner.lua",
    "bc8bc4714cd774fb5c748a0697ba828b3a8a895227c012751be22c46c718442c",
  ],
  [
    "luacov/stats.lua",
    "238536d46a20d42b0a1fabd1f347c1d6903cfc4ffa9d668fc33fcd97f87ea122",
  ],
  [
    "luacov/util.lua",
    "fbae18bc623c5275f6bf675183754c42a360fc190de5bf8d42892b1d266cfbef",
  ],
]);

for (const [relativePath, expectedHash] of expectedFiles) {
  const contents = await readFile(join(vendorRoot, relativePath));
  const actualHash = createHash("sha256").update(contents).digest("hex");

  if (actualHash !== expectedHash) {
    throw new Error(
      `vendored LuaCov checksum mismatch for ${relativePath}: ${actualHash}`,
    );
  }
}

const runner = await readFile(join(vendorRoot, "luacov", "runner.lua"), "utf8");
if (!runner.includes('runner.version = "0.17.0"')) {
  throw new Error("vendored LuaCov runner does not report version 0.17.0");
}

console.log(
  `coverage tools: LuaCov 0.17.0 (b1f9eae), Node ${process.versions.node}`,
);
