import { realpath as fsRealpath } from "node:fs/promises";
import { DEFAULT_HEADER_BYTES, readFirstLine as defaultReadFirstLine } from "./file-header.mjs";
import { isWithinCanonicalRoot } from "./paths.mjs";

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
