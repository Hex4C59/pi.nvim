import { open, realpath as fsRealpath } from "node:fs/promises";
import { homedir as osHomedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const CONFIRM_TOOLS = new Set(["bash", "edit", "write"]);
const PLAN_TOOLS = new Set(["read", "grep", "find", "ls", "todo"]);
const PERMISSION_MODES = new Set(["manual", "acceptEdits", "auto", "plan"]);
const PERMISSION_CHOICES = ["Block", "Allow once", "Allow for session"];
const PERMISSION_MODE_STATUS = "pi.permission_mode";
const UNICODE_SPACES = /[\u00a0\u2000-\u200a\u202f\u205f\u3000]/g;
const DEFAULT_PREVIEW_BYTES = 4 * 1024;
const DEFAULT_HEADER_BYTES = 64 * 1024;

function preview(value, maximum = DEFAULT_PREVIEW_BYTES) {
  const text = String(value ?? "");
  if (Buffer.byteLength(text) <= maximum) return text;
  let end = maximum;
  while (end > 0 && Buffer.byteLength(text.slice(0, end)) > maximum) end -= 1;
  return `${text.slice(0, end)}\n[preview truncated]`;
}

function block(reason) {
  return { block: true, reason };
}

function pathInput(event) {
  const value = event.input?.path ?? event.input?.file_path;
  if (value == null && event.toolName !== "read") return ".";
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function resolveLikePi(input, cwd, options = {}) {
  if (typeof input !== "string") throw new TypeError("path must be a string");
  let normalized = input.replace(UNICODE_SPACES, " ");
  if (normalized.startsWith("@")) normalized = normalized.slice(1);
  const home = typeof options.homedir === "function" ? options.homedir() : (options.homedir ?? osHomedir());
  const platform = options.platform ?? process.platform;
  if (normalized === "~") normalized = home;
  else if (normalized.startsWith("~/") || (platform === "win32" && normalized.startsWith("~\\"))) {
    normalized = path.join(home, normalized.slice(2));
  }
  if (/^file:\/\//.test(normalized)) normalized = fileURLToPath(normalized);
  return path.isAbsolute(normalized) ? path.resolve(normalized) : path.resolve(cwd, normalized);
}

function readVariants(candidate) {
  const nfd = candidate.normalize("NFD");
  const curly = candidate.replace(/'/g, "\u2019");
  return [candidate, candidate.replace(/ (AM|PM)\./gi, "\u202f$1."), nfd, curly, nfd.replace(/'/g, "\u2019")].filter(
    (value, index, values) => values.indexOf(value) === index,
  );
}

export async function canonicalTarget(input, cwd, options = {}) {
  const realpath = options.realpath ?? fsRealpath;
  const candidate = resolveLikePi(input, cwd, options);
  const candidates = options.readVariants === false ? [candidate] : readVariants(candidate);
  let lastError;
  for (const value of candidates) {
    try {
      return await realpath(value);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error("unable to canonicalize path");
}

export function isWithinCanonicalRoot(root, target) {
  const relative = path.relative(root, target);
  return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

async function canonicalRoot(ctx, options, cache) {
  if (typeof ctx?.cwd !== "string" || ctx.cwd.length === 0) throw new Error("working directory is unavailable");
  if (cache.has(ctx.cwd)) return cache.get(ctx.cwd);
  const canonical = await (options.realpath ?? fsRealpath)(ctx.cwd);
  cache.set(ctx.cwd, canonical);
  return canonical;
}

async function selectWithTimeout(ctx, title, choices, options) {
  if (!ctx?.hasUI || typeof ctx.ui?.select !== "function") throw new Error("permission UI is unavailable");
  const select = options.select ?? ((promptTitle, promptChoices) => ctx.ui.select(promptTitle, promptChoices));
  const startTimer = options.setTimeout ?? setTimeout;
  const stopTimer = options.clearTimeout ?? clearTimeout;
  const timeoutMs = options.timeoutMs;
  let timer;
  try {
    const selection = Promise.resolve().then(() => select(title, choices, ctx));
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return await selection;
    return await Promise.race([
      selection,
      new Promise((_, reject) => {
        timer = startTimer(() => reject(new Error("permission request timed out")), timeoutMs);
      }),
    ]);
  } finally {
    if (timer != null) stopTimer(timer);
  }
}

async function canonicalMutation(event, ctx, options) {
  const target = event.input?.path ?? event.input?.file_path;
  if (typeof target !== "string" || target.length === 0) throw new Error(`${event.toolName} path is missing`);
  const candidate = resolveLikePi(target, ctx.cwd, options);
  const realpath = options.realpath ?? fsRealpath;
  if (event.toolName === "write") {
    try {
      return await realpath(candidate);
    } catch {
      return path.join(await realpath(path.dirname(candidate)), path.basename(candidate));
    }
  }
  return canonicalTarget(target, ctx.cwd, { ...options, readVariants: false });
}

async function mutationRequest(event, ctx, options, root) {
  if (event.toolName === "bash") {
    const command = event.input?.command;
    if (typeof command !== "string" || command.length === 0) throw new Error("bash command is missing");
    return {
      approvalKey: `bash\0${root}\0${command}`,
      title: `Bash command\n${preview(command)}`,
    };
  }
  const canonical = await canonicalMutation(event, ctx, options);
  if (event.toolName === "write") {
    const content = event.input?.content;
    if (typeof content !== "string") throw new Error("write content is missing");
    return {
      approvalKey: `write\0${canonical}`,
      canonical,
      title: `File write\n${preview(canonical)}\n${Buffer.byteLength(content)} bytes`,
    };
  }
  const edits = event.input?.edits;
  if (!Array.isArray(edits)) throw new Error("edit operations are missing");
  const summary = Array.isArray(edits) ? `${edits.length} edit${edits.length === 1 ? "" : "s"}` : "file edit";
  return {
    approvalKey: `edit\0${canonical}`,
    canonical,
    title: `File edit\n${preview(canonical)}\n${summary}`,
  };
}

export function normalizePermissionMode(value) {
  if (typeof value !== "string") return undefined;
  const compact = value.trim().replace(/[\s_-]/g, "").toLowerCase();
  if (compact === "manual" || compact === "default" || compact === "confirm") return "manual";
  if (compact === "acceptedits") return "acceptEdits";
  if (compact === "auto") return "auto";
  if (compact === "plan") return "plan";
  return undefined;
}

export function permissionModeGuidance(mode) {
  const guidance = {
    manual: `Permission mode: Manual
- Workspace reads proceed normally.
- Bash commands, file edits/writes, and outside-workspace reads require user confirmation.
- Do not claim an operation succeeded until its tool result confirms it.`,
    acceptEdits: `Permission mode: Accept Edits
- Canonical edits and writes inside the current workspace proceed without confirmation.
- Bash commands, outside-workspace reads, and outside-workspace file changes still require user confirmation.
- Do not claim an operation succeeded until its tool result confirms it.`,
    auto: `Permission mode: Auto
- Structurally valid built-in tool calls proceed without confirmation, including Bash and outside-workspace access.
- Extension tools remain governed by their owning Extensions.
- Do not claim an operation succeeded until its tool result confirms it.`,
    plan: `[PLAN MODE ACTIVE]
You are in read-only planning mode.
- Use only read, grep, find, ls, and todo for exploration and plan tracking.
- Do not run Bash commands, edit or write files, or call other tools.
- Analyze the request, ask any necessary questions in text, and produce a concrete implementation plan.
- Do not make changes or claim that changes were made.`,
  };
  return guidance[mode] ?? guidance.manual;
}

export function createPermissionToolModeController(api) {
  let toolsBeforePlan;

  const activeTools = () => {
    const tools = api?.getActiveTools?.();
    return Array.isArray(tools) ? [...new Set(tools)] : [];
  };
  const planTools = (tools) => tools.filter((name) => PLAN_TOOLS.has(name));
  const setTools = (tools) => {
    if (typeof api?.setActiveTools !== "function") throw new Error("active tool control is unavailable");
    api.setActiveTools(tools);
  };

  return {
    onModeChange(next, previous) {
      if (next === "plan" && previous !== "plan") {
        toolsBeforePlan = activeTools();
        try {
          setTools(planTools(toolsBeforePlan));
        } catch (error) {
          toolsBeforePlan = undefined;
          throw error;
        }
      } else if (previous === "plan" && next !== "plan") {
        if (toolsBeforePlan) setTools(toolsBeforePlan);
        toolsBeforePlan = undefined;
      }
    },
    enforce(mode) {
      if (mode !== "plan") return;
      const current = activeTools();
      const restricted = planTools(current);
      if (current.length !== restricted.length || current.some((name, index) => name !== restricted[index])) {
        setTools(restricted);
      }
    },
    snapshot: () => toolsBeforePlan && [...toolsBeforePlan],
    clear: () => {
      toolsBeforePlan = undefined;
    },
  };
}

export function createPermissionController(options = {}) {
  const rootCache = new Map();
  const approvals = new Map();
  let mode = "manual";
  let toolCallGate = Promise.resolve();

  const publishStatus = async (ctx) => {
    const publish = options.publishStatus ?? ((key, value) => ctx.ui.setStatus(key, value));
    if (ctx?.hasUI && typeof publish === "function") {
      await publish(PERMISSION_MODE_STATUS, mode, ctx);
    }
  };

  const ask = async (ctx, request) => {
    if (approvals.has(request.approvalKey)) return undefined;
    const choice = await selectWithTimeout(ctx, request.title, PERMISSION_CHOICES, options);
    if (choice === "Allow once") return undefined;
    if (choice === "Allow for session") {
      approvals.set(request.approvalKey, true);
      return undefined;
    }
    if (choice === "Block" || choice == null) return block("Blocked by the user");
    return block("Blocked because the permission response was invalid");
  };

  const evaluateToolCall = async (event, ctx) => {
    try {
      if (mode === "plan" && !PLAN_TOOLS.has(event.toolName)) {
        return block("Plan mode allows read-only exploration tools only");
      }
      if (CONFIRM_TOOLS.has(event.toolName)) {
        const root = await canonicalRoot(ctx, options, rootCache);
        const request = await mutationRequest(event, ctx, options, root);
        if (request.canonical) {
          if (typeof event.input?.path === "string") event.input.path = request.canonical;
          else if (typeof event.input?.file_path === "string") event.input.file_path = request.canonical;
        }
        if (mode === "auto") return undefined;
        if (mode === "acceptEdits" && event.toolName !== "bash" && isWithinCanonicalRoot(root, request.canonical)) {
          return undefined;
        }
        return await ask(ctx, request);
      }
      if (!READ_TOOLS.has(event.toolName)) return undefined;
      const requested = pathInput(event);
      if (!requested) return block("Blocked because the tool path is missing");
      const root = await canonicalRoot(ctx, options, rootCache);
      const target = await canonicalTarget(requested, ctx.cwd, options);
      if (mode !== "auto" && !isWithinCanonicalRoot(root, target)) {
        const result = await ask(ctx, {
          approvalKey: `${event.toolName}\0${target}`,
          title: `Read outside workspace\n${event.toolName}\n${preview(target)}`,
        });
        if (result) return result;
      }
      event.input.path = target;
      return undefined;
    } catch (error) {
      return block(`Blocked: ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  const onToolCall = (event, ctx) => {
    const evaluation = toolCallGate.then(
      () => evaluateToolCall(event, ctx),
      () => evaluateToolCall(event, ctx),
    );
    toolCallGate = evaluation.then(
      () => undefined,
      () => undefined,
    );
    return evaluation;
  };

  const setMode = async (value, ctx) => {
    const next = normalizePermissionMode(value);
    if (!next || !PERMISSION_MODES.has(next)) return false;
    const previous = mode;
    if (next !== previous && typeof options.onModeChange === "function") {
      await options.onModeChange(next, previous, ctx);
    }
    mode = next;
    approvals.clear();
    if (ctx) {
      try {
        await publishStatus(ctx);
      } catch (error) {
        ctx.ui?.notify?.(`Permission mode changed, but status sync failed: ${error instanceof Error ? error.message : String(error)}`, "warning");
      }
    }
    return true;
  };

  const onSessionStart = async (_event, ctx) => {
    const previous = mode;
    let resetError;
    if (previous !== "manual" && typeof options.onModeChange === "function") {
      try {
        await options.onModeChange("manual", previous, ctx);
      } catch (error) {
        resetError = error;
      }
    }
    mode = resetError && previous === "plan" ? "plan" : "manual";
    approvals.clear();
    rootCache.clear();
    try {
      await publishStatus(ctx);
    } catch {
      // Status publication is display-only and cannot change the enforced mode.
    }
    if (resetError) {
      ctx.ui?.notify?.(
        `Permission mode reset failed; remaining in ${mode}: ${resetError instanceof Error ? resetError.message : String(resetError)}`,
        "warning",
      );
    }
  };

  const onSessionShutdown = () => {
    approvals.clear();
    rootCache.clear();
  };

  const onBeforeAgentStart = (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n${permissionModeGuidance(mode)}`,
  });

  const command = async (args, ctx) => {
    let requested = String(args ?? "").trim();
    if (!requested) {
      try {
        requested = await selectWithTimeout(ctx, "Permission mode", [...PERMISSION_MODES], options);
      } catch (error) {
        ctx.ui?.notify?.(`Permission mode unchanged: ${error instanceof Error ? error.message : String(error)}`, "error");
        return;
      }
    }
    try {
      if (!(await setMode(requested, ctx))) {
        ctx.ui?.notify?.(`Unknown permission mode: ${requested}`, "error");
      }
    } catch (error) {
      ctx.ui?.notify?.(`Permission mode unchanged: ${error instanceof Error ? error.message : String(error)}`, "error");
    }
  };

  return {
    onToolCall,
    onSessionStart,
    onSessionShutdown,
    onBeforeAgentStart,
    command,
    setMode,
    getMode: () => mode,
    clearApprovals: () => approvals.clear(),
    approvalCount: () => approvals.size,
  };
}

export function createPermissionHandler(options = {}) {
  return createPermissionController(options).onToolCall;
}

export function createWorkspaceGuard(options = {}) {
  const rootCache = new Map();
  return async (event, ctx) => {
    if (!READ_TOOLS.has(event.toolName)) return undefined;
    try {
      const requested = pathInput(event);
      if (!requested) return block("Blocked because the tool path is missing");
      const root = await canonicalRoot(ctx, options, rootCache);
      const target = await canonicalTarget(requested, ctx.cwd, options);
      if (!isWithinCanonicalRoot(root, target)) return block("Blocked because the path is outside the workspace");
      event.input.path = target;
      return undefined;
    } catch (error) {
      return block(`Blocked because the path could not be verified: ${error instanceof Error ? error.message : String(error)}`);
    }
  };
}

export function parseSessionHeader(line) {
  let header;
  try {
    header = JSON.parse(String(line).replace(/\r$/, ""));
  } catch {
    throw new Error("invalid session header JSON");
  }
  if (!header || header.type !== "session") throw new Error("first record is not a session header");
  if (!Number.isInteger(header.version) || header.version < 1 || header.version > 3) {
    throw new Error("unsupported session version");
  }
  if (typeof header.cwd !== "string" || header.cwd.trim() === "") throw new Error("session cwd is missing");
  return header;
}

async function defaultReadFirstLine(file, maximum = DEFAULT_HEADER_BYTES) {
  const handle = await open(file, "r");
  try {
    const buffer = Buffer.alloc(maximum + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    const newline = buffer.subarray(0, bytesRead).indexOf(0x0a);
    if (newline < 0 && bytesRead > maximum) throw new Error("session header is too large");
    if (newline < 0) throw new Error("session header must end with a newline");
    return buffer.subarray(0, newline).toString("utf8");
  } finally {
    await handle.close();
  }
}

export function createSessionRootGuard(options = {}) {
  return async (event, ctx) => {
    if (event.reason === "new") return undefined;
    if (event.reason !== "resume") return { cancel: true };
    try {
      if (typeof event.targetSessionFile !== "string" || event.targetSessionFile.length === 0) {
        throw new Error("target session file is missing");
      }
      const readFirstLine = options.readFirstLine ?? defaultReadFirstLine;
      const line = await readFirstLine(event.targetSessionFile, options.maxHeaderBytes ?? DEFAULT_HEADER_BYTES);
      const header = parseSessionHeader(line);
      const realpath = options.realpath ?? fsRealpath;
      const [root, targetRoot] = await Promise.all([realpath(ctx.cwd), realpath(header.cwd)]);
      if (!isWithinCanonicalRoot(root, targetRoot) || !isWithinCanonicalRoot(targetRoot, root)) {
        throw new Error("cross-project session resume is not allowed");
      }
      return undefined;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      if (ctx?.hasUI && ctx.ui?.notify) {
        try {
          ctx.ui.notify(`Session switch blocked: ${reason}`, "error");
        } catch {
          // Notification failure must not change the deny decision.
        }
      }
      return { cancel: true };
    }
  };
}
