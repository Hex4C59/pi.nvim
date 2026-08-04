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
    { type: "thinking", thinking: "**Inspecting RPC event flow**\n\nlive reasoning" },
    { type: "text", text: "# Analysis\n\nlive answer\n\n> structured response\n\n```lua\nlocal ready = true\n```" },
  ],
  stopReason: "stop",
};
let delayedPrompt;
let freshSession = false;
let autoRetryEnabled = true;
let resourceGeneration = 0;
let permissionMode = "manual";
let activeModel = { provider: "fake", id: "fixture", contextWindow: 100000 };

const requestContent = (request) => request.content ?? [
  { type: "text", text: request.message ?? "" },
  ...(request.images ?? []),
];
const requestText = (request) => requestContent(request)
  .filter((block) => block.type === "text")
  .map((block) => block.text)
  .join("");

const runPrompt = (request, userText) => {
  respond(request);
  const suffix = request.id || "anonymous";
  send({ type: "agent_start" });
  send({
    type: "message_start",
    message: { role: "user", content: userText === undefined ? requestContent(request) : [{ type: "text", text: userText }] },
  });
  send({ type: "message_start", message: { role: "assistant", content: [] } });
  send({
    type: "message_update",
    message: { role: "assistant", content: [] },
    assistantMessageEvent: { type: "thinking_start", contentIndex: 0 },
  });
  send({
    type: "message_update",
    message: {
      role: "assistant",
      content: [{ type: "thinking", thinking: "**Inspecting RPC event flow**" }],
    },
    assistantMessageEvent: {
      type: "thinking_delta",
      contentIndex: 0,
      delta: "**Inspecting RPC event flow**",
    },
  });
  send({
    type: "message_update",
    message: assistant,
    assistantMessageEvent: { type: "text_delta", contentIndex: 1, delta: "live answer" },
  });
  send({ type: "message_end", message: assistant });
  send({ type: "tool_execution_start", toolCallId: `fixture-tool-${suffix}`, toolName: "read", args: { path: "fixture.txt" } });
  send({ type: "tool_execution_update", toolCallId: `fixture-tool-${suffix}`, toolName: "read", partialResult: { content: [{ type: "text", text: "partial output" }] } });
  send({ type: "tool_execution_end", toolCallId: `fixture-tool-${suffix}`, toolName: "read", result: { content: [{ type: "text", text: "final output" }] }, isError: false });
  send({ type: "tool_execution_start", toolCallId: `fixture-edit-${suffix}`, toolName: "edit", args: { path: "lua/example.lua", edits: [{ oldText: "local old = true", newText: "local ready = true" }] } });
  send({
    type: "tool_execution_end",
    toolCallId: `fixture-edit-${suffix}`,
    toolName: "edit",
    result: {
      content: [{ type: "text", text: "Updated lua/example.lua" }],
      details: {
        diff: "- 7 local old = true\n+ 7 local ready = true",
        firstChangedLine: 7,
      },
    },
    isError: false,
  });
  send({ type: "queue_update", steering: [], followUp: [] });
  send({ type: "agent_settled" });
};

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  const respondToRequest = (data = {}) => respond(request, data);

  if (request.type === "get_state") {
    respondToRequest({
      model: activeModel,
      thinkingLevel: "high",
      isStreaming: false,
      autoCompactionEnabled: true,
      autoRetryEnabled,
      sessionId: freshSession ? "fixture-fresh" : "fixture-session",
      rpcCapabilities: ["history_pagination", "administrative_workflows", "ordered_prompt_content"],
    });
    send({ type: "extension_ui_request", method: "setStatus", statusKey: "pi.permission_mode", statusText: permissionMode });
    if (!freshSession) {
      send({
        type: "extension_ui_request",
        method: "setWidget",
        widgetKey: "pi.todo",
        widgetLines: resourceGeneration === 0
          ? ["Tasks · 1/2 complete", "◐ #2 Run RPC tests", "✓ #1 Load Extension"]
          : ["Tasks · reloaded", "✓ Reloaded RPC resources"],
        widgetPlacement: "aboveEditor",
      });
    }
  } else if (request.type === "set_auto_retry") {
    autoRetryEnabled = request.enabled;
    respondToRequest();
  } else if (request.type === "get_messages_page") {
    if (request.limit !== 50 || request.maxBytes !== 1024 * 1024) {
      send({
        id: request.id,
        type: "response",
        command: request.type,
        success: false,
        error: "unexpected history page budget",
      });
    } else if (freshSession) {
      respondToRequest({ items: [], nextCursor: null, hasMore: false, leafId: null });
    } else if (request.cursor === "fixture-history:middle") {
      respondToRequest({
        items: [{
          entryId: "history-middle",
          messages: [{ role: "user", content: [{ type: "text", text: "middle history question" }] }],
        }],
        nextCursor: "fixture-history:oldest",
        hasMore: true,
        leafId: "fixture-history-leaf",
      });
    } else if (request.cursor === "fixture-history:oldest") {
      respondToRequest({
        items: [{
          entryId: "history-oldest",
          messages: [{ role: "assistant", content: [{ type: "text", text: "oldest history answer" }], stopReason: "stop" }],
        }],
        nextCursor: null,
        hasMore: false,
        leafId: "fixture-history-leaf",
      });
    } else if (request.cursor === "fixture-history:stale") {
      respondToRequest({
        items: [],
        nextCursor: null,
        hasMore: false,
        leafId: "stale-history-leaf",
      });
    } else {
      respondToRequest({
        items: [
          {
            entryId: "history-question",
            messages: [{ role: "user", content: [{ type: "text", text: "history question" }] }],
          },
          {
            entryId: "history-answer",
            messages: [{ role: "assistant", content: [{ type: "text", text: "history answer" }], stopReason: "stop" }],
          },
        ],
        nextCursor: "fixture-history:middle",
        hasMore: true,
        leafId: "fixture-history-leaf",
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
      { name: "fixture-dialog-cancel", description: "Cancel a dialog", source: "extension" },
      { name: "permissions", description: "Select permission mode", source: "extension" },
      { name: "mode", description: "Removed alias", source: "extension" },
      { name: "llama", description: "Removed backend command", source: "extension" },
      { name: "todos", description: "Show or hide todos", source: "extension" },
      { name: "fixture-template", description: "Fixture prompt template", source: "prompt" },
    ] });
  } else if (request.type === "get_auth_providers") {
    respondToRequest({ providers: [{
      id: "fixture",
      name: "Fixture",
      configured: false,
      methods: [{ type: "api_key", name: "API key", interactive: true }],
    }] });
  } else if (request.type === "begin_auth") {
    respondToRequest({ flowId: "fixture-auth-flow" });
    setImmediate(() => send({
      type: "auth_prompt",
      flowId: "fixture-auth-flow",
      promptId: "fixture-auth-prompt",
      promptType: "secret",
      message: "Fixture provider secret",
      placeholder: "secret",
      sensitive: true,
    }));
  } else if (request.type === "submit_auth_value") {
    if (request.flowId !== "fixture-auth-flow"
      || request.promptId !== "fixture-auth-prompt"
      || request.value !== "fixture-private-secret") {
      send({ id: request.id, type: "response", command: request.type, success: false, error: "invalid fixture secret" });
    } else {
      respondToRequest();
      send({
        type: "auth_complete",
        flowId: "fixture-auth-flow",
        provider: "fixture",
        method: "api_key",
        success: true,
      });
    }
  } else if (request.type === "cancel_auth") {
    respondToRequest();
    send({
      type: "auth_complete",
      flowId: "fixture-auth-flow",
      provider: "fixture",
      method: "api_key",
      success: false,
      cancelled: true,
    });
  } else if (request.type === "get_available_models") {
    respondToRequest({ models: [
      { provider: "fake", id: "fixture", contextWindow: 100000 },
      { provider: "fake", id: "fixture-alt", contextWindow: 64000 },
    ] });
  } else if (request.type === "set_model") {
    activeModel = {
      provider: request.provider,
      id: request.modelId,
      contextWindow: request.modelId === "fixture-alt" ? 64000 : 100000,
    };
    respondToRequest();
  } else if (request.type === "reload_resources") {
    resourceGeneration += 1;
    respondToRequest({
      reloaded: ["extensions", "skills", "prompts", "themes"],
      resources: { extensions: 1, skills: 1, prompts: 1, themes: 1 },
    });
  } else if (request.type === "get_project_trust") {
    respondToRequest({ cwd: process.cwd(), active: false, saved: null, restartRequired: false });
  } else if (request.type === "set_project_trust") {
    respondToRequest({
      cwd: process.cwd(),
      active: false,
      saved: request.decision === "unset" ? null : { path: process.cwd(), decision: request.decision },
      restartRequired: request.decision !== "untrusted",
    });
  } else if (request.type === "get_model_scope" || request.type === "set_model_scope") {
    const available = [{ provider: "fake", id: "fixture" }];
    respondToRequest({ available, enabled: available, allEnabled: true, persistedPatterns: [] });
  } else if (request.type === "logout_provider") {
    respondToRequest();
  } else if (request.type === "prompt") {
    const promptText = requestText(request);
    if (promptText === "/fixture-noop") {
      respondToRequest();
    } else if (promptText.startsWith("/permissions ")) {
      permissionMode = promptText.slice("/permissions ".length);
      respondToRequest();
      send({
        type: "extension_ui_request",
        method: "setStatus",
        statusKey: "pi.permission_mode",
        statusText: permissionMode,
      });
    } else if (promptText === "/fixture-prefill") {
      respondToRequest();
      send({ type: "extension_ui_request", id: "fixture-prefill", method: "set_editor_text", text: "extension draft" });
    } else if (promptText === "/fixture-clear") {
      respondToRequest();
      send({ type: "extension_ui_request", id: "fixture-clear", method: "set_editor_text", text: "" });
    } else if (promptText === "/fixture-dialog-cancel") {
      respondToRequest();
      send({
        type: "extension_ui_request",
        id: "fixture-dialog-cancel",
        method: "input",
        title: "Temporary input",
        placeholder: "waiting",
      });
      setTimeout(() => {
        send({ type: "extension_ui_cancel", id: "fixture-dialog-cancel", reason: "timeout" });
      }, 25);
    } else if (promptText === "first accepted") {
      delayedPrompt = request;
    } else if (promptText === "second rejected") {
      send({ id: request.id, type: "response", command: "prompt", success: false, error: "fixture rejection" });
      if (delayedPrompt) {
        runPrompt(delayedPrompt);
        delayedPrompt = undefined;
      }
    } else {
      const userText = promptText.startsWith("/fixture-template")
        ? "expanded template payload"
        : undefined;
      runPrompt(request, userText);
    }
  } else if (request.type === "extension_ui_response" && request.id === "fixture-dialog-cancel") {
    send({ type: "extension_error", error: "late dialog response" });
  } else if (request.type === "abort") {
    respondToRequest();
    send({ type: "agent_settled" });
  } else if (request.type === "new_session") {
    freshSession = true;
    respondToRequest({ cancelled: false });
    send({ type: "extension_ui_request", method: "setStatus", statusKey: "pi.permission_mode", statusText: permissionMode });
    send({ type: "extension_ui_request", method: "setWidget", widgetKey: "pi.todo" });
  } else {
    respondToRequest();
  }
});
