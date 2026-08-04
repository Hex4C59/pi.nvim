import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
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

async function smokeAutoRetryState() {
  const cwd = await mkdtemp(path.join(tmpdir(), "pi-retry-state-smoke-"));
  const agentDir = path.join(cwd, "agent");
  await mkdir(agentDir);
  try {
    const messages = await new Promise((resolve, reject) => {
      const child = spawn(
        piCommand,
        ["--mode", "rpc", "--no-session", "--no-context-files", "--no-approve"],
        {
          cwd,
          env: { ...process.env, PI_CODING_AGENT_DIR: agentDir },
          stdio: ["pipe", "pipe", "pipe"],
        },
      );
      const received = [];
      let stdout = "";
      let stderr = "";
      let expected;
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("auto-retry state smoke timed out"));
      }, 8000);

      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
        while (stdout.includes("\n")) {
          const newline = stdout.indexOf("\n");
          const line = stdout.slice(0, newline).replace(/\r$/, "");
          stdout = stdout.slice(newline + 1);
          if (!line) continue;
          try {
            const message = JSON.parse(line);
            received.push(message);
            if (message.id === "retry-before") {
              assert.equal(typeof message.data?.autoRetryEnabled, "boolean", "get_state omitted auto-retry state");
              expected = !message.data.autoRetryEnabled;
              child.stdin.write(
                `${JSON.stringify({ type: "set_auto_retry", id: "retry-set", enabled: expected })}\n`,
              );
            } else if (message.id === "retry-set") {
              assert.equal(message.success, true, "set_auto_retry failed");
              child.stdin.write(`${JSON.stringify({ type: "get_state", id: "retry-after" })}\n`);
            } else if (message.id === "retry-after") {
              assert.equal(message.data?.autoRetryEnabled, expected, "get_state returned stale auto-retry state");
              child.stdin.end(`${JSON.stringify({ type: "abort", id: "retry-done" })}\n`);
            }
          } catch (error) {
            clearTimeout(timer);
            child.kill("SIGKILL");
            reject(error);
          }
        }
      });
      child.on("error", reject);
      child.on("close", (code) => {
        clearTimeout(timer);
        if (code === 0) resolve(received);
        else reject(new Error(`auto-retry state smoke exited ${code}: ${stderr}`));
      });
      child.stdin.write(`${JSON.stringify({ type: "get_state", id: "retry-before" })}\n`);
    });
    assert.equal(messages.find((message) => message.id === "retry-done")?.success, true, "retry smoke did not settle");
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}

async function smokeDialogCancellation() {
  const cwd = await mkdtemp(path.join(tmpdir(), "pi-dialog-cancel-smoke-"));
  try {
    const messages = await new Promise((resolve, reject) => {
      const child = spawn(
        piCommand,
        [
          "--mode",
          "rpc",
          "--no-session",
          "--no-context-files",
          "--no-approve",
          "--extension",
          path.join(repository, "tests", "smoke", "dialog_timeout.ts"),
        ],
        { cwd, stdio: ["pipe", "pipe", "pipe"] },
      );
      const received = [];
      let stdout = "";
      let stderr = "";
      let dialogId;
      let sentLateResponse = false;
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("dialog cancellation smoke timed out"));
      }, 8000);

      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
        while (stdout.includes("\n")) {
          const newline = stdout.indexOf("\n");
          const line = stdout.slice(0, newline).replace(/\r$/, "");
          stdout = stdout.slice(newline + 1);
          if (!line) continue;
          try {
            const message = JSON.parse(line);
            received.push(message);
            if (message.type === "extension_ui_request" && message.method === "input") {
              dialogId = message.id;
            }
            if (message.type === "extension_ui_cancel" && !sentLateResponse) {
              assert.equal(message.id, dialogId, "dialog cancellation used the wrong request ID");
              assert.equal(message.reason, "timeout", "dialog cancellation used the wrong reason");
              sentLateResponse = true;
              child.stdin.end(
                `${JSON.stringify({ type: "extension_ui_response", id: dialogId, value: "late" })}\n${JSON.stringify({ type: "get_state", id: "after-late" })}\n`,
              );
            }
          } catch (error) {
            clearTimeout(timer);
            child.kill("SIGKILL");
            reject(error);
          }
        }
      });
      child.on("error", reject);
      child.on("close", (code) => {
        clearTimeout(timer);
        if (code === 0) resolve(received);
        else reject(new Error(`dialog cancellation smoke exited ${code}: ${stderr}`));
      });
      child.stdin.write(`${JSON.stringify({ type: "prompt", id: "dialog-command", message: "/smoke-dialog-timeout" })}\n`);
    });

    assert.equal(
      messages.find((message) => message.id === "dialog-command")?.success,
      true,
      "dialog command failed",
    );
    assert.equal(
      messages.find((message) => message.id === "after-late")?.success,
      true,
      "late dialog response disrupted RPC",
    );
    assert.equal(
      messages.some((message) => message.type === "extension_error"),
      false,
      "dialog cancellation produced an extension error",
    );
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

await smokeAutoRetryState();
await smokeDialogCancellation();

console.log("extensions_smoke: ok");
