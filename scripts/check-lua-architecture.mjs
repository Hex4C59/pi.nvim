#!/usr/bin/env node

import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");

function parseArguments(argv) {
  let root = repositoryRoot;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--root" && argv[index + 1]) {
      root = path.resolve(argv[index + 1]);
      index += 1;
    } else {
      throw new Error(`usage: check-lua-architecture.mjs [--root <repository>]`);
    }
  }
  return root;
}

async function luaFiles(directory) {
  const result = [];
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  for (const entry of entries) {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...(await luaFiles(target)));
    else if (entry.isFile() && entry.name.endsWith(".lua")) result.push(target);
  }
  return result;
}

function longBracket(source, offset) {
  if (source[offset] !== "[") return undefined;
  let cursor = offset + 1;
  while (source[cursor] === "=") cursor += 1;
  if (source[cursor] !== "[") return undefined;
  const equals = source.slice(offset + 1, cursor);
  const close = `]${equals}]`;
  const contentStart = cursor + 1;
  const closeStart = source.indexOf(close, contentStart);
  const end = closeStart < 0 ? source.length : closeStart + close.length;
  const value = source.slice(contentStart, closeStart < 0 ? source.length : closeStart);
  return { end, value };
}

function tokens(source) {
  const result = [];
  let offset = 0;
  let line = 1;

  const advance = (next) => {
    for (let index = offset; index < next; index += 1) {
      if (source[index] === "\n") line += 1;
    }
    offset = next;
  };

  while (offset < source.length) {
    const character = source[offset];
    if (/\s/.test(character)) {
      advance(offset + 1);
      continue;
    }
    if (source.startsWith("--", offset)) {
      const block = longBracket(source, offset + 2);
      if (block) advance(block.end);
      else {
        const newline = source.indexOf("\n", offset + 2);
        advance(newline < 0 ? source.length : newline);
      }
      continue;
    }
    if (character === "'" || character === '"') {
      const tokenLine = line;
      const quote = character;
      let cursor = offset + 1;
      let value = "";
      while (cursor < source.length) {
        const current = source[cursor];
        if (current === quote) {
          cursor += 1;
          break;
        }
        if (current === "\\" && cursor + 1 < source.length) {
          const escaped = source[cursor + 1];
          const escapes = { n: "\n", r: "\r", t: "\t" };
          value += escapes[escaped] ?? escaped;
          cursor += 2;
        } else {
          value += current;
          cursor += 1;
        }
      }
      result.push({ type: "string", value, line: tokenLine });
      advance(cursor);
      continue;
    }
    const block = longBracket(source, offset);
    if (block) {
      result.push({ type: "string", value: block.value, line });
      advance(block.end);
      continue;
    }
    const identifier = source.slice(offset).match(/^[A-Za-z_][A-Za-z0-9_]*/)?.[0];
    if (identifier) {
      result.push({ type: "identifier", value: identifier, line });
      advance(offset + identifier.length);
      continue;
    }
    result.push({ type: "punctuation", value: character, line });
    advance(offset + 1);
  }
  return result;
}

function requiresFrom(moduleTokens) {
  const requires = [];
  for (let index = 0; index < moduleTokens.length; index += 1) {
    const token = moduleTokens[index];
    const previous = moduleTokens[index - 1];
    if (
      token.type !== "identifier" ||
      token.value !== "require" ||
      previous?.value === "." ||
      previous?.value === ":"
    ) {
      continue;
    }
    let cursor = index + 1;
    if (moduleTokens[cursor]?.value === "(") cursor += 1;
    const argument = moduleTokens[cursor];
    if (argument?.type === "string" && (argument.value === "pi" || argument.value.startsWith("pi."))) {
      requires.push({ module: argument.value, line: token.line });
    }
  }
  return requires;
}

const privateChatFields = new Set([
  "transcript",
  "transcript_view",
  "input_area",
  "command_menu",
  "permission_area",
  "widget_area",
  "image_backend",
  "image_preview",
  "position",
  "process_expanded",
]);

const runtimeOwnedClientFields = new Set([
  "commands_by_name",
  "stats_pending",
  "display_queue",
  "runtime_unsubscribe",
  "bash_running",
]);

function chatLeaks(moduleTokens) {
  const leaks = [];
  for (let index = 0; index < moduleTokens.length; index += 1) {
    if (moduleTokens[index].type !== "identifier" || moduleTokens[index].value !== "chat") continue;
    const previous = moduleTokens[index - 1];
    const receiver = moduleTokens[index - 2];
    const directChat = previous?.value !== ".";
    const componentChat = previous?.value === "." && receiver?.type === "identifier" && receiver.value === "self";
    if (!directChat && !componentChat) continue;
    const separator = moduleTokens[index + 1];
    const field = moduleTokens[index + 2];
    if (separator?.value === "." && field?.type === "identifier" && privateChatFields.has(field.value)) {
      leaks.push({ field: field.value, line: moduleTokens[index].line });
    } else if (
      separator?.value === "[" &&
      field?.type === "string" &&
      privateChatFields.has(field.value) &&
      moduleTokens[index + 3]?.value === "]"
    ) {
      leaks.push({ field: field.value, line: moduleTokens[index].line });
    }
  }
  return leaks;
}

function clientStateLeaks(moduleTokens) {
  const leaks = [];
  for (let index = 0; index < moduleTokens.length; index += 1) {
    if (moduleTokens[index].type !== "identifier" || moduleTokens[index].value !== "client") continue;
    const separator = moduleTokens[index + 1];
    const field = moduleTokens[index + 2];
    if (separator?.value === "." && field?.type === "identifier" && runtimeOwnedClientFields.has(field.value)) {
      leaks.push({ field: field.value, line: moduleTokens[index].line });
    } else if (
      separator?.value === "[" &&
      field?.type === "string" &&
      runtimeOwnedClientFields.has(field.value) &&
      moduleTokens[index + 3]?.value === "]"
    ) {
      leaks.push({ field: field.value, line: moduleTokens[index].line });
    }
  }
  return leaks;
}

function moduleName(luaRoot, file) {
  let relative = path.relative(luaRoot, file).split(path.sep).join("/");
  relative = relative.replace(/\.lua$/, "").replace(/\/init$/, "");
  return relative === "init" || relative === "" ? "pi" : `pi.${relative.replaceAll("/", ".")}`;
}

function hasPrefix(value, prefix) {
  return value === prefix || value.startsWith(`${prefix}.`);
}

function dependencyViolation(source, dependency) {
  if (hasPrefix(source, "pi.ui") && dependency === "pi") {
    return "UI modules must receive frontend actions instead of requiring pi";
  }
  if (
    (hasPrefix(source, "pi.ui.render") || hasPrefix(source, "pi.ui.transcript") || source === "pi.ui.transcript_view") &&
    hasPrefix(dependency, "pi.ui.image") &&
    dependency !== "pi.ui.image"
  ) {
    return "transcript and renderer modules must use the stable image facade";
  }
  if (
    ["pi.ui.transcript.projection", "pi.ui.transcript.retention", "pi.ui.transcript.history"].includes(source) &&
    (dependency === "pi.ui.transcript" || dependency === "pi.ui.transcript.view" || dependency === "pi.ui.transcript_view")
  ) {
    return "transcript helpers must not depend on the stateful model or view";
  }
  if (source === "pi.ui.transcript.view" && hasPrefix(dependency, "pi.ui.transcript")) {
    return "transcript view must receive model state through injected providers";
  }
  if (hasPrefix(source, "pi.protocol") && ["pi.client", "pi.runtime", "pi.commands", "pi.ui"].some((prefix) => hasPrefix(dependency, prefix))) {
    return "protocol must remain a transport-independent leaf";
  }
  if (hasPrefix(source, "pi.client") && ["pi.runtime", "pi.commands", "pi.ui"].some((prefix) => hasPrefix(dependency, prefix))) {
    return "client must not depend on runtime, commands, or UI";
  }
  if (hasPrefix(source, "pi.ui.render") && ["pi.runtime", "pi.client", "pi.commands"].some((prefix) => hasPrefix(dependency, prefix))) {
    return "renderer modules must not depend on orchestration layers";
  }
  if (hasPrefix(source, "pi.commands") && hasPrefix(dependency, "pi.ui")) {
    return "command modules must use runtime and public facades instead of concrete UI modules";
  }
  return undefined;
}

// Reviewed exceptions are represented here rather than silently excluded. The
// list is intentionally empty after Task 03 removed the remaining cycles and
// Chat component-field leaks.
const knownCycleEdges = new Set();
const knownFacadeLeaks = new Map();

function findCycle(adjacency) {
  const state = new Map();
  const stack = [];
  const visit = (module) => {
    state.set(module, "visiting");
    stack.push(module);
    for (const dependency of adjacency.get(module) ?? []) {
      if (state.get(dependency) === "visiting") {
        return [...stack.slice(stack.indexOf(dependency)), dependency];
      }
      if (!state.has(dependency)) {
        const cycle = visit(dependency);
        if (cycle) return cycle;
      }
    }
    stack.pop();
    state.set(module, "visited");
    return undefined;
  };
  for (const module of [...adjacency.keys()].sort()) {
    if (!state.has(module)) {
      const cycle = visit(module);
      if (cycle) return cycle;
    }
  }
  return undefined;
}

async function check(root) {
  const luaRoot = path.join(root, "lua", "pi");
  const files = await luaFiles(luaRoot);
  const modules = [];
  for (const file of files) {
    const source = await readFile(file, "utf8");
    const moduleTokens = tokens(source);
    modules.push({
      file,
      relative: path.relative(root, file).split(path.sep).join("/"),
      name: moduleName(luaRoot, file),
      requires: requiresFrom(moduleTokens),
      leaks: chatLeaks(moduleTokens),
      clientStateLeaks: clientStateLeaks(moduleTokens),
    });
  }

  const failures = [];
  const moduleNames = new Set(modules.map((module) => module.name));
  const adjacency = new Map(modules.map((module) => [module.name, []]));
  const useRepositoryBaseline = path.resolve(root) === repositoryRoot;

  for (const module of modules) {
    for (const dependency of module.requires) {
      const violation = dependencyViolation(module.name, dependency.module);
      if (violation) failures.push(`${module.relative}:${dependency.line}: ${violation}: ${dependency.module}`);
      const edge = `${module.name}->${dependency.module}`;
      if (moduleNames.has(dependency.module) && !(useRepositoryBaseline && knownCycleEdges.has(edge))) {
        adjacency.get(module.name).push(dependency.module);
      }
    }
  }

  const cycle = findCycle(adjacency);
  if (cycle) failures.push(`Lua require cycle: ${cycle.join(" -> ")}`);

  const leakCounts = new Map();
  for (const module of modules) {
    const compositionFile = module.relative === "lua/pi/ui/chat.lua";
    if (compositionFile) continue;
    for (const leak of module.leaks) {
      const key = `${module.relative}:${leak.field}`;
      leakCounts.set(key, (leakCounts.get(key) ?? 0) + 1);
      if (!useRepositoryBaseline || !knownFacadeLeaks.has(key)) {
        failures.push(`${module.relative}:${leak.line}: Chat facade leak: chat.${leak.field}`);
      }
    }
    for (const leak of module.clientStateLeaks) {
      failures.push(`${module.relative}:${leak.line}: Runtime-owned state leaked onto Client: client.${leak.field}`);
    }
  }

  if (useRepositoryBaseline) {
    for (const [key, expected] of knownFacadeLeaks) {
      const actual = leakCounts.get(key) ?? 0;
      if (actual !== expected) {
        failures.push(`Known Chat facade leak budget changed for ${key}: expected ${expected}, found ${actual}`);
      }
    }
  }

  if (failures.length > 0) throw new Error(failures.join("\n"));
}

try {
  const root = parseArguments(process.argv.slice(2));
  await check(root);
  console.log("check-lua-architecture: ok");
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
