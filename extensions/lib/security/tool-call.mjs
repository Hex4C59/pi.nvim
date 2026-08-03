const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);

export function isReadTool(name) {
  return READ_TOOLS.has(name);
}

export function blockToolCall(reason) {
  return { block: true, reason };
}

export function readPathInput(event) {
  const value = event.input?.path ?? event.input?.file_path;
  if (value == null && event.toolName !== "read") return ".";
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
