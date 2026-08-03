import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const piCommand = process.env.PI_COMMAND || "pi";

async function loadExtension(extension, requests = []) {
  const cwd = await mkdtemp(path.join(tmpdir(), "pi-extension-smoke-"));
  try {
    const output = await new Promise((resolve, reject) => {
      const child = spawn(
        piCommand,
        [
          "--mode",
          "rpc",
          "--no-session",
          "--no-context-files",
          "--no-approve",
          "--extension",
          path.join(repository, "extensions", extension),
        ],
        { cwd, stdio: ["pipe", "pipe", "pipe"] },
      );
      let stdout = "";
      let stderr = "";
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error(`${extension} smoke timed out`));
      }, 8000);
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
      child.on("error", reject);
      child.on("close", (code) => {
        clearTimeout(timer);
        if (code === 0) resolve(stdout);
        else reject(new Error(`${extension} exited ${code}: ${stderr}`));
      });
      const input = [
        { type: "get_state", id: "smoke" },
        ...requests,
        { type: "abort", id: "done" },
      ].map((request) => JSON.stringify(request)).join("\n");
      child.stdin.end(`${input}\n`);
    });
    assert.doesNotMatch(output, /extension_error/);
    const response = output
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line))
      .find((message) => message.id === "smoke");
    assert.equal(response?.success, true, `${extension} did not answer get_state`);
    const messages = output.trim().split("\n").map((line) => JSON.parse(line));
    for (const request of requests) {
      const requestResponse = messages.find((message) => message.id === request.id);
      assert.equal(requestResponse?.success, true, `${extension} failed request ${request.id}`);
    }
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}

for (const extension of ["permission-gate.ts", "workspace-guard.ts", "session-root-guard.ts", "todo.ts"]) {
  const requests = extension === "permission-gate.ts"
    ? [
        { type: "prompt", id: "plan-mode", message: "/permissions plan" },
        { type: "prompt", id: "manual-mode", message: "/permissions manual" },
      ]
    : [];
  await loadExtension(extension, requests);
}

console.log("extensions_smoke: ok");
