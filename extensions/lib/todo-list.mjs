const TODO_VERSION = 1;
const MAX_TODOS = 100;
const MAX_TEXT_BYTES = 500;
const MIN_PLAN_TODOS = 2;
const MAX_PLAN_TODOS = 12;

export const TODO_STATUSES = ["pending", "in_progress", "completed"];

const STATUS_SET = new Set(TODO_STATUSES);
const ACTION_SET = new Set(["list", "plan", "add", "update", "remove", "clear"]);

export class TodoError extends Error {
  constructor(message) {
    super(message);
    this.name = "TodoError";
  }
}

function emptyState() {
  return { todos: [], nextId: 1 };
}

function cloneTodo(todo) {
  return { id: todo.id, text: todo.text, status: todo.status };
}

function cloneState(state) {
  return {
    todos: state.todos.map(cloneTodo),
    nextId: state.nextId,
  };
}

function normalizeText(value) {
  if (typeof value !== "string") throw new TodoError("text is required");
  const text = value.replace(/\s+/gu, " ").trim();
  if (!text) throw new TodoError("text must not be empty");
  if (Buffer.byteLength(text, "utf8") > MAX_TEXT_BYTES) {
    throw new TodoError(`text must not exceed ${MAX_TEXT_BYTES} bytes`);
  }
  return text;
}

function normalizePlan(value) {
  if (!Array.isArray(value)) throw new TodoError("tasks are required for plan");
  if (value.length < MIN_PLAN_TODOS || value.length > MAX_PLAN_TODOS) {
    throw new TodoError(`plan requires ${MIN_PLAN_TODOS}-${MAX_PLAN_TODOS} tasks`);
  }
  const tasks = value.map(normalizeText);
  if (new Set(tasks).size !== tasks.length) throw new TodoError("plan tasks must be unique");
  return tasks;
}

function requireId(value) {
  if (!Number.isSafeInteger(value) || value < 1) throw new TodoError("id must be a positive integer");
  return value;
}

function requireStatus(value) {
  if (!STATUS_SET.has(value)) {
    throw new TodoError(`status must be one of: ${TODO_STATUSES.join(", ")}`);
  }
  return value;
}

function validPersistedState(details) {
  if (!details || details.version !== TODO_VERSION || !Array.isArray(details.todos)) return undefined;
  if (!Number.isSafeInteger(details.nextId) || details.nextId < 1 || details.todos.length > MAX_TODOS) return undefined;

  const ids = new Set();
  const todos = [];
  let largestId = 0;
  for (const todo of details.todos) {
    if (!todo || !Number.isSafeInteger(todo.id) || todo.id < 1 || ids.has(todo.id)) return undefined;
    if (typeof todo.text !== "string" || !todo.text.trim() || Buffer.byteLength(todo.text, "utf8") > MAX_TEXT_BYTES) {
      return undefined;
    }
    if (!STATUS_SET.has(todo.status)) return undefined;
    ids.add(todo.id);
    largestId = Math.max(largestId, todo.id);
    todos.push(cloneTodo(todo));
  }
  if (details.nextId <= largestId) return undefined;
  return { todos, nextId: details.nextId };
}

export function stateFromBranch(entries) {
  let state = emptyState();
  for (const entry of entries ?? []) {
    if (entry?.type !== "message") continue;
    const message = entry.message;
    if (message?.role !== "toolResult" || message.toolName !== "todo") continue;
    const restored = validPersistedState(message.details);
    if (restored) state = restored;
  }
  return cloneState(state);
}

function details(action, state) {
  return {
    version: TODO_VERSION,
    action,
    todos: state.todos.map(cloneTodo),
    nextId: state.nextId,
  };
}

function formatList(todos) {
  if (todos.length === 0) return "No todos.";
  const markers = { pending: " ", in_progress: "~", completed: "x" };
  return todos.map((todo) => `[${markers[todo.status]}] #${todo.id}: ${todo.text}`).join("\n");
}

export function createTodoController() {
  let state = emptyState();

  const activate = (id) => {
    for (const todo of state.todos) {
      if (todo.id !== id && todo.status === "in_progress") todo.status = "pending";
    }
  };

  const find = (id) => {
    const todo = state.todos.find((candidate) => candidate.id === id);
    if (!todo) throw new TodoError(`todo #${id} was not found`);
    return todo;
  };

  const promoteNext = () => {
    if (state.todos.some((todo) => todo.status === "in_progress")) return;
    const next = state.todos.find((todo) => todo.status === "pending");
    if (next) next.status = "in_progress";
  };

  const execute = (params = {}) => {
    const action = params.action;
    if (!ACTION_SET.has(action)) throw new TodoError("unknown todo action");

    let message;
    if (action === "list") {
      message = formatList(state.todos);
    } else if (action === "plan") {
      const tasks = normalizePlan(params.tasks);
      state = {
        todos: tasks.map((text, index) => ({
          id: index + 1,
          text,
          status: index === 0 ? "in_progress" : "pending",
        })),
        nextId: tasks.length + 1,
      };
      message = `Created plan with ${tasks.length} tasks.\n${formatList(state.todos)}`;
    } else if (action === "add") {
      if (state.todos.length >= MAX_TODOS) throw new TodoError(`todo list is limited to ${MAX_TODOS} items`);
      const status = params.status === undefined ? "pending" : requireStatus(params.status);
      const todo = { id: state.nextId++, text: normalizeText(params.text), status };
      if (status === "in_progress") activate(todo.id);
      state.todos.push(todo);
      message = `Added todo #${todo.id}: ${todo.text}`;
    } else if (action === "update") {
      const id = requireId(params.id);
      const todo = find(id);
      if (params.text === undefined && params.status === undefined) {
        throw new TodoError("update requires text or status");
      }
      const text = params.text === undefined ? undefined : normalizeText(params.text);
      const status = params.status === undefined ? undefined : requireStatus(params.status);
      if (text !== undefined) todo.text = text;
      if (status !== undefined) {
        todo.status = status;
        if (todo.status === "in_progress") activate(todo.id);
        else if (todo.status === "completed") promoteNext();
      }
      message = `Updated todo #${todo.id}: ${todo.status}`;
    } else if (action === "remove") {
      const id = requireId(params.id);
      find(id);
      state.todos = state.todos.filter((todo) => todo.id !== id);
      promoteNext();
      message = `Removed todo #${id}.`;
    } else {
      const count = state.todos.length;
      state = emptyState();
      message = `Cleared ${count} todo${count === 1 ? "" : "s"}.`;
    }

    return {
      message,
      details: details(action, state),
    };
  };

  return {
    execute,
    restore(entries) {
      state = stateFromBranch(entries);
      return cloneState(state);
    },
    snapshot() {
      return cloneState(state);
    },
  };
}

export function renderTodoWidget(state, options = {}) {
  const todos = state?.todos ?? [];
  if (todos.length === 0) return undefined;

  const maximum = Math.max(1, Math.floor(options.maxItems ?? 12));
  const completed = todos.filter((todo) => todo.status === "completed").length;
  const rank = { in_progress: 0, pending: 1, completed: 2 };
  const ordered = [...todos].sort((left, right) => rank[left.status] - rank[right.status] || left.id - right.id);
  const symbols = { pending: "○", in_progress: "◐", completed: "✓" };
  const lines = [`Plan · ${completed}/${todos.length} complete`];
  for (const todo of ordered.slice(0, maximum)) {
    lines.push(`${symbols[todo.status]} #${todo.id} ${todo.text}`);
  }
  if (ordered.length > maximum) lines.push(`… ${ordered.length - maximum} more`);
  return lines;
}

export function todoWorkflowGuidance() {
  return `Task planning workflow:
- For a complex implementation request with at least three meaningful steps, use the todo tool before substantive implementation. After only the minimum inspection needed to understand scope, call todo with action "plan" and 3-7 concrete, verifiable tasks.
- Do not create a plan for a simple question or a single small change. Do not pad a plan with trivial filler steps.
- If the current branch already has unfinished tasks for the same request, continue and update that plan instead of replacing it. Use todo with action "list" when the current state is unclear.
- Keep exactly one task in_progress. When a task is finished and verified, update it to completed immediately; the todo tool will promote the next pending task automatically.
- Keep the plan aligned with actual work. Add, update, or remove tasks when scope changes, and never mark work completed before its verification succeeds.
- Before the final response, ensure every task is completed or explicitly explain why any task remains pending.`;
}
