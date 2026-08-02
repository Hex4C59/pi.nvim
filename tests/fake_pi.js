#!/usr/bin/env node

const readline = require("node:readline");

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const assistant = {
  role: "assistant",
  content: [
    { type: "thinking", thinking: "live reasoning" },
    { type: "text", text: "# Analysis\n\nlive answer\n\n> structured response\n\n```lua\nlocal ready = true\n```" },
  ],
  stopReason: "stop",
};

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  const respond = (data = {}) => send({
    id: request.id,
    type: "response",
    command: request.type,
    success: true,
    data,
  });

  if (request.type === "get_state") {
    respond({
      model: { provider: "fake", id: "fixture", contextWindow: 100000 },
      thinkingLevel: "high",
      isStreaming: false,
      autoCompactionEnabled: true,
    });
  } else if (request.type === "get_messages") {
    respond({
      messages: [
        { role: "user", content: [{ type: "text", text: "history question" }] },
        { role: "assistant", content: [{ type: "text", text: "history answer" }], stopReason: "stop" },
      ],
    });
  } else if (request.type === "get_session_stats") {
    respond({ tokens: { input: 10, output: 5, cacheRead: 20 }, contextUsage: { tokens: 35, contextWindow: 100000, percent: 0.035 }, cost: 0.001 });
  } else if (request.type === "get_commands") {
    respond({ commands: [{ name: "fixture", description: "Fixture command", source: "extension" }] });
  } else if (request.type === "prompt") {
    respond();
    send({ type: "agent_start" });
    send({ type: "message_start", message: { role: "user", content: [{ type: "text", text: request.message }] } });
    send({ type: "message_start", message: { role: "assistant", content: [] } });
    send({ type: "message_update", message: assistant, assistantMessageEvent: { type: "text_delta", delta: "live answer" } });
    send({ type: "message_end", message: assistant });
    send({ type: "tool_execution_start", toolCallId: "fixture-tool", toolName: "read", args: { path: "fixture.txt" } });
    send({ type: "tool_execution_update", toolCallId: "fixture-tool", toolName: "read", partialResult: { content: [{ type: "text", text: "partial output" }] } });
    send({ type: "tool_execution_end", toolCallId: "fixture-tool", toolName: "read", result: { content: [{ type: "text", text: "final output" }] }, isError: false });
    send({ type: "tool_execution_start", toolCallId: "fixture-edit", toolName: "edit", args: { path: "lua/example.lua", edits: [{ oldText: "local old = true", newText: "local ready = true" }] } });
    send({ type: "tool_execution_end", toolCallId: "fixture-edit", toolName: "edit", result: { content: [{ type: "text", text: "Updated lua/example.lua" }] }, isError: false });
    send({ type: "queue_update", steering: [], followUp: [] });
    send({ type: "agent_settled" });
  } else if (request.type === "abort") {
    respond();
    send({ type: "agent_settled" });
  } else {
    respond();
  }
});
