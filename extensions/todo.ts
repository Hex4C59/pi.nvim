import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { createTodoController, renderTodoWidget, todoWorkflowGuidance } from "./lib/todo-list.mjs";

const WIDGET_KEY = "pi.todo";
const TODO_STATUS_VALUES = ["pending", "in_progress", "completed"] as const;
const TodoParams = Type.Object({
  action: StringEnum(["list", "plan", "add", "update", "remove", "clear"] as const, {
    description: "Todo operation to perform",
  }),
  tasks: Type.Optional(
    Type.Array(Type.String({ description: "Concrete task text" }), {
      description: "Complete ordered task list for the plan action",
      minItems: 2,
      maxItems: 12,
    }),
  ),
  id: Type.Optional(Type.Number({ description: "Todo ID for update or remove" })),
  text: Type.Optional(Type.String({ description: "Todo text for add or update" })),
  status: Type.Optional(StringEnum(TODO_STATUS_VALUES, {
    description: "Todo status for add or update",
  })),
});

export default function todoExtension(pi: ExtensionAPI) {
  const todos = createTodoController();
  let visible = true;

  const publish = (ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    const lines = visible ? renderTodoWidget(todos.snapshot()) : undefined;
    ctx.ui.setWidget(WIDGET_KEY, lines, { placement: "aboveEditor" });
  };

  const restore = (_event: unknown, ctx: ExtensionContext) => {
    todos.restore(ctx.sessionManager.getBranch());
    publish(ctx);
  };

  pi.on("session_start", restore);
  pi.on("session_tree", restore);
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n${todoWorkflowGuidance()}`,
  }));
  pi.on("session_shutdown", (_event, ctx) => {
    if (ctx.hasUI) ctx.ui.setWidget(WIDGET_KEY, undefined);
  });

  pi.registerTool({
    name: "todo",
    label: "Todo",
    description:
      "Plan and track the current branch's work. Create an ordered plan in one call, then add, update, remove, list, or clear tasks as execution progresses.",
    promptSnippet: "Decompose complex work into a persistent, status-tracked plan",
    promptGuidelines: [
      "Use todo with action plan for work with at least three meaningful steps; skip todo for trivial single-step requests.",
      "Keep the todo plan current: mark each task completed immediately after verification; the next pending task becomes in_progress automatically.",
      "Before finishing, resolve every todo task or explain why it remains pending.",
    ],
    parameters: TodoParams,
    // Pi prepares every sibling tool before parallel execution. This lets a
    // pending permission request stop the whole batch before todo mutates state.
    executionMode: "parallel",

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const result = todos.execute(params);
      publish(ctx);
      return {
        content: [{ type: "text", text: result.message }],
        details: result.details,
      };
    },
  });

  pi.registerCommand("todos", {
    description: "Show or hide the current branch's task plan",
    handler: async (args, ctx) => {
      const action = String(args ?? "").trim().toLowerCase() || "show";
      if (action !== "show" && action !== "hide") {
        ctx.ui.notify("Usage: /todos [show|hide]", "error");
        return;
      }
      visible = action === "show";
      publish(ctx);
      if (visible && todos.snapshot().todos.length === 0) {
        ctx.ui.notify("No todos on the current branch", "info");
      }
    },
  });
}
