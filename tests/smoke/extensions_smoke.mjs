import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
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

async function smokeSessionDiscoveryAndNavigation() {
  const cwd = await mkdtemp(path.join(tmpdir(), "pi-session-rpc-smoke-"));
  const agentDir = path.join(cwd, "agent");
  const sessionDir = path.join(cwd, "sessions");
  const sessionFile = path.join(sessionDir, "session.jsonl");
  await mkdir(agentDir);
  await mkdir(sessionDir);
  const timestamp = "2026-08-04T08:00:00.000Z";
  const entries = [
    { type: "session", version: 3, id: "smoke-session", timestamp, cwd },
    { type: "session_info", id: "info", parentId: null, timestamp, name: "RPC smoke" },
    { type: "model_change", id: "model", parentId: "info", timestamp, provider: "fixture", modelId: "model-a" },
    {
      type: "message",
      id: "u1",
      parentId: "model",
      timestamp,
      message: { role: "user", content: "first prompt", timestamp: Date.parse(timestamp) },
    },
    {
      type: "message",
      id: "a1",
      parentId: "u1",
      timestamp,
      message: {
        role: "assistant",
        content: [{ type: "text", text: "first reply" }],
        api: "anthropic-messages",
        provider: "fixture",
        model: "model-a",
        usage: {
          input: 1,
          output: 1,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.parse(timestamp) + 1,
      },
    },
    {
      type: "message",
      id: "u2",
      parentId: "a1",
      timestamp,
      message: { role: "user", content: "current prompt", timestamp: Date.parse(timestamp) + 2 },
    },
  ];
  await writeFile(sessionFile, `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`, "utf8");

  try {
    const messages = await new Promise((resolve, reject) => {
      const child = spawn(
        piCommand,
        [
          "--mode",
          "rpc",
          "--session",
          sessionFile,
          "--session-dir",
          sessionDir,
          "--no-context-files",
          "--no-approve",
        ],
        {
          cwd,
          env: { ...process.env, PI_CODING_AGENT_DIR: agentDir },
          stdio: ["pipe", "pipe", "pipe"],
        },
      );
      const received = [];
      let stdout = "";
      let stderr = "";
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("session discovery/navigation smoke timed out"));
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
            if (message.id === "session-state") {
              assert.equal(message.data?.rpcCapabilities?.includes("list_sessions"), true);
              assert.equal(message.data?.rpcCapabilities?.includes("navigate_tree"), true);
              child.stdin.write(`${JSON.stringify({ type: "list_sessions", id: "session-list", limit: 1 })}\n`);
            } else if (message.id === "session-list") {
              assert.equal(message.success, true, "list_sessions failed");
              assert.equal(message.data?.sessions?.[0]?.path, sessionFile);
              assert.equal(message.data?.sessions?.[0]?.name, "RPC smoke");
              assert.deepEqual(message.data?.sessions?.[0]?.model, { provider: "fixture", id: "model-a" });
              child.stdin.write(`${JSON.stringify({ type: "get_tree", id: "tree-before" })}\n`);
            } else if (message.id === "tree-before") {
              const containsTarget = message.data?.tree?.some(function contains(node) {
                return node.entry?.id === "a1" || node.children?.some(contains);
              });
              assert.equal(containsTarget, true, "get_tree omitted the navigation target");
              child.stdin.write(
                `${JSON.stringify({ type: "navigate_tree", id: "navigate", entryId: "a1", summarize: false })}\n`,
              );
            } else if (message.id === "navigate") {
              assert.deepEqual(message.data, { cancelled: false, leafId: "a1" });
              child.stdin.write(`${JSON.stringify({ type: "get_tree", id: "tree-after" })}\n`);
            } else if (message.id === "tree-after") {
              assert.equal(message.data?.leafId, "a1", "navigation did not persist the active leaf");
              child.stdin.end(`${JSON.stringify({ type: "abort", id: "session-done" })}\n`);
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
        else reject(new Error(`session discovery/navigation smoke exited ${code}: ${stderr}`));
      });
      child.stdin.write(`${JSON.stringify({ type: "get_state", id: "session-state" })}\n`);
    });
    assert.equal(messages.find((message) => message.id === "session-done")?.success, true);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}

async function smokeLargeHistoryPagination() {
  const cwd = await mkdtemp(path.join(tmpdir(), "pi-large-history-smoke-"));
  const agentDir = path.join(cwd, "agent");
  const sessionDir = path.join(cwd, "sessions");
  const sessionFile = path.join(sessionDir, "large-session.jsonl");
  await mkdir(agentDir);
  await mkdir(sessionDir);
  const timestamp = "2026-08-04T09:00:00.000Z";
  const largeText = "x".repeat(11 * 1024 * 1024);
  const entries = [
    { type: "session", version: 3, id: "large-smoke-session", timestamp, cwd },
    {
      type: "message",
      id: "huge-user",
      parentId: null,
      timestamp,
      message: { role: "user", content: largeText, timestamp: Date.parse(timestamp) },
    },
    {
      type: "message",
      id: "small-assistant",
      parentId: "huge-user",
      timestamp,
      message: {
        role: "assistant",
        content: [{ type: "text", text: "bounded recent reply" }],
        api: "anthropic-messages",
        provider: "fixture",
        model: "model-a",
        usage: {
          input: 1,
          output: 1,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.parse(timestamp) + 1,
      },
    },
    {
      type: "message",
      id: "recent-user",
      parentId: "small-assistant",
      timestamp,
      message: { role: "user", content: "bounded recent prompt", timestamp: Date.parse(timestamp) + 2 },
    },
  ];
  await writeFile(sessionFile, `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`, "utf8");

  try {
    const messages = await new Promise((resolve, reject) => {
      const child = spawn(
        piCommand,
        [
          "--mode",
          "rpc",
          "--session",
          sessionFile,
          "--session-dir",
          sessionDir,
          "--no-context-files",
          "--no-approve",
        ],
        {
          cwd,
          env: { ...process.env, PI_CODING_AGENT_DIR: agentDir },
          stdio: ["pipe", "pipe", "pipe"],
        },
      );
      const received = [];
      let stdout = "";
      let stderr = "";
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("large history pagination smoke timed out"));
      }, 15000);
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
            if (message.id === "large-history-state") {
              assert.equal(message.data?.rpcCapabilities?.includes("history_pagination"), true);
              child.stdin.write(`${JSON.stringify({
                type: "get_messages_page",
                id: "large-history-newest",
                limit: 2,
                maxBytes: 1024 * 1024,
              })}\n`);
            } else if (message.id === "large-history-newest") {
              assert.equal(message.success, true, "newest bounded history page failed");
              assert.equal(Buffer.byteLength(line) + 1 <= 1024 * 1024, true, "newest history frame exceeded maxBytes");
              assert.equal(message.data?.hasMore, true, "large session did not expose an older page");
              assert.equal(typeof message.data?.nextCursor, "string", "large session omitted its continuation cursor");
              child.stdin.write(`${JSON.stringify({
                type: "get_messages_page",
                id: "large-history-oldest",
                cursor: message.data.nextCursor,
                limit: 2,
                maxBytes: 1024 * 1024,
              })}\n`);
            } else if (message.id === "large-history-oldest") {
              assert.equal(message.success, true, "oldest bounded history page failed");
              assert.equal(Buffer.byteLength(line) + 1 <= 1024 * 1024, true, "oldest history frame exceeded maxBytes");
              const omission = message.data?.items?.find((item) => item.omitted === true);
              assert.equal(omission?.reason, "max_bytes", "oversized history entry was not represented structurally");
              assert.equal(omission?.originalBytes > 10 * 1024 * 1024, true, "omission did not describe the large entry");
              child.stdin.end(`${JSON.stringify({ type: "abort", id: "large-history-done" })}\n`);
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
        else reject(new Error(`large history pagination smoke exited ${code}: ${stderr}`));
      });
      child.stdin.write(`${JSON.stringify({ type: "get_state", id: "large-history-state" })}\n`);
    });
    assert.equal(messages.find((message) => message.id === "large-history-done")?.success, true);
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
await smokeSessionDiscoveryAndNavigation();
await smokeLargeHistoryPagination();

console.log("extensions_smoke: ok");
