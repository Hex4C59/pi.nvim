#!/usr/bin/env node

import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

const ignoredDirectories = new Set([".git", "coverage", "node_modules"]);

function fail(message) {
  process.stderr.write(`check-documentation: ${message}\n`);
  process.exit(1);
}

function parseRoot(arguments_) {
  if (arguments_.length === 0) return process.cwd();
  if (arguments_.length === 2 && arguments_[0] === "--root") return arguments_[1];
  fail("usage: check-documentation.mjs [--root <repository>]");
}

const requestedRoot = resolve(parseRoot(process.argv.slice(2)));
if (!existsSync(requestedRoot) || !lstatSync(requestedRoot).isDirectory()) {
  fail(`repository root is not a directory: ${requestedRoot}`);
}
const repositoryRoot = realpathSync(requestedRoot);

function insideRepository(path) {
  const child = relative(repositoryRoot, path);
  return child === "" || (!child.startsWith(`..${sep}`) && child !== ".." && !isAbsolute(child));
}

function markdownFiles(directory, output = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) markdownFiles(path, output);
    else if (entry.isFile() && entry.name.toLowerCase().endsWith(".md")) output.push(path);
  }
  return output;
}

function withoutFencedCode(source) {
  return source.replace(/^ {0,3}(```|~~~).*?^ {0,3}\1\s*$/gms, (block) => block.replace(/[^\n]/g, ""));
}

function lineNumber(source, offset) {
  return source.slice(0, offset).split("\n").length;
}

function cleanDestination(raw) {
  let destination = raw.startsWith("<") && raw.endsWith(">") ? raw.slice(1, -1) : raw;
  try {
    destination = decodeURIComponent(destination);
  } catch {
    return null;
  }
  return destination.split("#", 1)[0].split("?", 1)[0];
}

function isExternal(destination) {
  return (
    destination === "" ||
    destination.startsWith("#") ||
    destination.startsWith("/") ||
    /^[A-Za-z][A-Za-z0-9+.-]*:/.test(destination)
  );
}

const errors = [];

for (const file of markdownFiles(repositoryRoot).sort()) {
  const relativeFile = relative(repositoryRoot, file);
  const source = readFileSync(file, "utf8");
  const prose = withoutFencedCode(source);

  const linkPattern = /!?\[[^\]\n]*\]\((<[^>\n]+>|[^)\s]+)(?:\s+["'][^)\n]*["'])?\)/g;
  for (const match of prose.matchAll(linkPattern)) {
    const destination = cleanDestination(match[1]);
    if (destination === null) {
      errors.push(`${relativeFile}:${lineNumber(prose, match.index)}: invalid URL encoding in Markdown link: ${match[1]}`);
      continue;
    }
    if (isExternal(destination)) continue;
    const target = resolve(dirname(file), destination);
    if (!insideRepository(target) || !existsSync(target)) {
      errors.push(`${relativeFile}:${lineNumber(prose, match.index)}: broken local Markdown link: ${destination}`);
    }
  }

  const documentReferencePattern = /`((?:docs|tests|lua|extensions|plugin|scripts|\.github)\/[^`\n]*?\.md)`/g;
  for (const match of prose.matchAll(documentReferencePattern)) {
    const destination = match[1];
    if (/[*?{}$<>]/.test(destination)) continue;
    const target = resolve(repositoryRoot, destination);
    if (!insideRepository(target) || !existsSync(target)) {
      errors.push(`${relativeFile}:${lineNumber(prose, match.index)}: missing local document reference: ${destination}`);
    }
  }
}

const rootInstructions = resolve(repositoryRoot, "AGENTS.md");
if (existsSync(rootInstructions)) {
  const source = readFileSync(rootInstructions, "utf8");
  const section = source.match(/^## Repository Map\s*$([\s\S]*?)(?=^## |(?![\s\S]))/m);
  const codeBlock = section?.[1].match(/```text\s*\n([\s\S]*?)```/);
  if (!codeBlock) {
    errors.push("AGENTS.md: Repository Map must contain a text code block");
  } else {
    for (const line of codeBlock[1].split("\n")) {
      const path = line.trim().split(/\s+/, 1)[0];
      if (!path) continue;
      const target = resolve(repositoryRoot, path);
      if (!insideRepository(target) || !existsSync(target)) {
        errors.push(`AGENTS.md: repository map path does not exist: ${path}`);
      }
    }
  }
}

if (errors.length > 0) {
  for (const error of errors.sort()) process.stderr.write(`${error}\n`);
  process.exit(1);
}

process.stdout.write("check-documentation: ok\n");
