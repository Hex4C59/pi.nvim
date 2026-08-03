#!/usr/bin/env node

const readline = require("node:readline");

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const respond = (request, data = {}) => send({
  id: request.id,
  type: "response",
  command: request.type,
  success: true,
  data,
});
const assistant = {
  role: "assistant",
  content: [
    { type: "thinking", thinking: "live reasoning" },
    { type: "text", text: "# Analysis\n\nlive answer\n\n> structured response\n\n```lua\nlocal ready = true\n```" },
  ],
  stopReason: "stop",
};
let delayedPrompt;
let freshSession = false;

const runPrompt = (request, userText = request.message) => {
  respond(request);
  const suffix = request.id || "anonymous";
  send({ type: "agent_start" });
  send({ type: "message_start", message: { role: "user", content: [{ type: "text", text: userText }] } });
  send({ type: "message_start", message: { role: "assistant", content: [] } });
  send({ type: "message_update", message: assistant, assistantMessageEvent: { type: "text_delta", delta: "live answer" } });
  send({ type: "message_end", message: assistant });
  send({ type: "tool_execution_start", toolCallId: `fixture-tool-${suffix}`, toolName: "read", args: { path: "fixture.txt" } });
  send({ type: "tool_execution_update", toolCallId: `fixture-tool-${suffix}`, toolName: "read", partialResult: { content: [{ type: "text", text: "partial output" }] } });
  send({ type: "tool_execution_end", toolCallId: `fixture-tool-${suffix}`, toolName: "read", result: { content: [{ type: "text", text: "final output" }] }, isError: false });
  send({ type: "tool_execution_start", toolCallId: `fixture-edit-${suffix}`, toolName: "edit", args: { path: "lua/example.lua", edits: [{ oldText: "local old = true", newText: "local ready = true" }] } });
  send({ type: "tool_execution_end", toolCallId: `fixture-edit-${suffix}`, toolName: "edit", result: { content: [{ type: "text", text: "Updated lua/example.lua" }] }, isError: false });
  send({ type: "queue_update", steering: [], followUp: [] });
  send({ type: "agent_settled" });
};

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  const respondToRequest = (data = {}) => respond(request, data);

  if (request.type === "get_state") {
    respondToRequest({
      model: { provider: "fake", id: "fixture", contextWindow: 100000 },
      thinkingLevel: "high",
      isStreaming: false,
      autoCompactionEnabled: true,
    });
    send({ type: "extension_ui_request", method: "setStatus", statusKey: "pi.permission_mode", statusText: "manual" });
    if (!freshSession) {
      send({
        type: "extension_ui_request",
        method: "setWidget",
        widgetKey: "pi.todo",
        widgetLines: ["Tasks · 1/2 complete", "◐ #2 Run RPC tests", "✓ #1 Load Extension"],
        widgetPlacement: "aboveEditor",
      });
    }
  } else if (request.type === "get_messages") {
    respondToRequest({
      messages: freshSession ? [] : [
        { role: "user", content: [{ type: "text", text: "history question" }] },
        { role: "assistant", content: [{ type: "text", text: "history answer" }], stopReason: "stop" },
      ],
    });
  } else if (request.type === "get_session_stats") {
    respondToRequest(freshSession
      ? { tokens: { input: 0, output: 0, cacheRead: 0 }, contextUsage: { tokens: 0, contextWindow: 100000, percent: 0 }, cost: 0 }
      : { tokens: { input: 10, output: 5, cacheRead: 20 }, contextUsage: { tokens: 35, contextWindow: 100000, percent: 0.035 }, cost: 0.001 });
  } else if (request.type === "get_commands") {
    respondToRequest({ commands: [
      { name: "fixture", description: "Fixture command", source: "extension" },
      { name: "fixture-noop", description: "No-op extension command", source: "extension" },
      { name: "fixture-prefill", description: "Prefill editor", source: "extension" },
      { name: "fixture-clear", description: "Clear editor", source: "extension" },
      { name: "permissions", description: "Select permission mode", source: "extension" },
      { name: "todos", description: "Show or hide todos", source: "extension" },
      { name: "fixture-template", description: "Fixture prompt template", source: "prompt" },
    ] });
  } else if (request.type === "prompt") {
    if (request.message === "/fixture-noop") {
      respondToRequest();
    } else if (request.message.startsWith("/permissions ")) {
      respondToRequest();
      send({
        type: "extension_ui_request",
        method: "setStatus",
        statusKey: "pi.permission_mode",
        statusText: request.message.slice("/permissions ".length),
      });
    } else if (request.message === "/fixture-prefill") {
      respondToRequest();
      send({ type: "extension_ui_request", id: "fixture-prefill", method: "set_editor_text", text: "extension draft" });
    } else if (request.message === "/fixture-clear") {
      respondToRequest();
      send({ type: "extension_ui_request", id: "fixture-clear", method: "set_editor_text", text: "" });
    } else if (request.message === "first accepted") {
      delayedPrompt = request;
    } else if (request.message === "second rejected") {
      send({ id: request.id, type: "response", command: "prompt", success: false, error: "fixture rejection" });
      if (delayedPrompt) {
        runPrompt(delayedPrompt);
        delayedPrompt = undefined;
      }
    } else {
      const userText = request.message.startsWith("/fixture-template")
        ? "expanded template payload"
        : request.message;
      runPrompt(request, userText);
    }
  } else if (request.type === "abort") {
    respondToRequest();
    send({ type: "agent_settled" });
  } else if (request.type === "new_session") {
    freshSession = true;
    respondToRequest({ cancelled: false });
    send({ type: "extension_ui_request", method: "setStatus", statusKey: "pi.permission_mode", statusText: "manual" });
    send({ type: "extension_ui_request", method: "setWidget", widgetKey: "pi.todo" });
  } else {
    respondToRequest();
  }
});
