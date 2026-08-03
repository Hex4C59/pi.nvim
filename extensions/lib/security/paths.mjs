import { realpath as fsRealpath } from "node:fs/promises";
import { homedir as osHomedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const UNICODE_SPACES = /[\u00a0\u2000-\u200a\u202f\u205f\u3000]/g;

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

export async function canonicalRoot(ctx, options, cache) {
  if (typeof ctx?.cwd !== "string" || ctx.cwd.length === 0) throw new Error("working directory is unavailable");
  if (cache.has(ctx.cwd)) return cache.get(ctx.cwd);
  const canonical = await (options.realpath ?? fsRealpath)(ctx.cwd);
  cache.set(ctx.cwd, canonical);
  return canonical;
}
