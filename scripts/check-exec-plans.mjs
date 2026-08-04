#!/usr/bin/env node

import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, isAbsolute, relative, resolve, sep } from "node:path";

const requiredSections = [
  "Purpose",
  "Progress",
  "Surprises And Discoveries",
  "Decision Log",
  "Context And Orientation",
  "Implementation Plan",
  "Validation And Acceptance",
  "Recovery And Idempotence",
  "Interfaces And Dependencies",
  "Outcomes And Retrospective",
];
const maximumPlanBytes = 256 * 1024;
const maximumErrors = 50;

function fail(message) {
  process.stderr.write(`check-exec-plans: ${message}\n`);
  process.exit(1);
}

function parseRoot(arguments_) {
  if (arguments_.length === 0) return process.cwd();
  if (arguments_.length === 2 && arguments_[0] === "--root") return arguments_[1];
  fail("usage: check-exec-plans.mjs [--root <repository>]");
}

const requestedRoot = resolve(parseRoot(process.argv.slice(2)));
if (!existsSync(requestedRoot) || !lstatSync(requestedRoot).isDirectory()) {
  fail(`repository root is not a directory: ${requestedRoot}`);
}
const repositoryRoot = realpathSync(requestedRoot);
const errors = [];
let omittedErrors = 0;

function addError(message) {
  if (errors.length < maximumErrors) errors.push(message);
  else omittedErrors += 1;
}

function insideRepository(path) {
  const child = relative(repositoryRoot, path);
  return child === "" || (!child.startsWith(`..${sep}`) && child !== ".." && !isAbsolute(child));
}

function requireRegularFile(path, label) {
  if (!existsSync(path)) {
    addError(`${label} does not exist`);
    return false;
  }
  const metadata = lstatSync(path);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    addError(`${label} must be a regular file`);
    return false;
  }
  return true;
}

function markdownHeadings(lines) {
  const headings = [];
  let fence = null;

  for (const [index, line] of lines.entries()) {
    const fenceMatch = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (fenceMatch) {
      const marker = fenceMatch[1];
      if (fence === null) fence = { character: marker[0], length: marker.length };
      else if (marker[0] === fence.character && marker.length >= fence.length) fence = null;
      continue;
    }
    if (fence !== null) continue;

    const heading = line.match(/^(#{1,6})\s+(.+?)\s*$/);
    if (heading) headings.push({ level: heading[1].length, name: heading[2], line: index + 1, index });
  }

  return headings;
}

function meaningfulSectionBody(lines, heading, nextHeading) {
  const body = lines.slice(heading.index + 1, nextHeading?.index ?? lines.length).join("\n");
  return body.replace(/<!--[\s\S]*?-->/g, "").trim().length > 0;
}

function validatePlan(path) {
  const name = basename(path);
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*\.md$/.test(name)) {
    addError(`${name}: plan filename must be lowercase kebab-case`);
  }
  if (statSync(path).size > maximumPlanBytes) {
    addError(`${name}: plan exceeds ${maximumPlanBytes} bytes`);
    return;
  }

  const source = readFileSync(path, "utf8");
  const lines = source.split(/\r?\n/);
  const nonEmpty = lines.map((line) => line.trim()).filter(Boolean);
  if (!/^# [^#].+/.test(nonEmpty[0] ?? "")) {
    addError(`${name}: first non-empty line must be one level-one title`);
  }
  if (nonEmpty[1] !== "Status: active") {
    addError(`${name}: second non-empty line must be exactly "Status: active"; remove completed plans`);
  }
  if (lines.filter((line) => line.trim() === "Status: active").length !== 1) {
    addError(`${name}: must contain exactly one active status line`);
  }

  const headings = markdownHeadings(lines);
  const levelOne = headings.filter((heading) => heading.level === 1);
  if (levelOne.length !== 1) addError(`${name}: must contain exactly one level-one title`);

  const sectionHeadings = headings.filter((heading) => heading.level === 2);
  const requiredIndexes = [];
  for (const required of requiredSections) {
    const matches = sectionHeadings.filter((heading) => heading.name === required);
    if (matches.length === 0) {
      addError(`${name}: missing required section: ## ${required}`);
      continue;
    }
    if (matches.length > 1) {
      addError(`${name}: duplicate required section: ## ${required}`);
      continue;
    }
    requiredIndexes.push(matches[0].index);

    const nextHeading = sectionHeadings.find((heading) => heading.index > matches[0].index);
    if (!meaningfulSectionBody(lines, matches[0], nextHeading)) {
      addError(`${name}: section is empty: ## ${required}`);
    }
  }
  if (requiredIndexes.length === requiredSections.length) {
    const sorted = [...requiredIndexes].sort((left, right) => left - right);
    if (requiredIndexes.some((value, index) => value !== sorted[index])) {
      addError(`${name}: required sections are out of order`);
    }
  }

  const progress = sectionHeadings.find((heading) => heading.name === "Progress");
  if (progress) {
    const nextHeading = sectionHeadings.find((heading) => heading.index > progress.index);
    const body = lines.slice(progress.index + 1, nextHeading?.index ?? lines.length).join("\n");
    const datedCheckbox = /^- \[(?: |x|X)\] \d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z)? - \S/m;
    if (!datedCheckbox.test(body)) {
      addError(`${name}: Progress must contain a dated checkbox entry`);
    }
  }
}

const guidePath = resolve(repositoryRoot, ".agent", "PLANS.md");
if (requireRegularFile(guidePath, ".agent/PLANS.md")) {
  const guide = readFileSync(guidePath, "utf8");
  for (const required of requiredSections) {
    if (!guide.includes(`## ${required}`)) {
      addError(`.agent/PLANS.md: template is missing required section: ## ${required}`);
    }
  }
}

const plansDirectory = resolve(repositoryRoot, ".agent", "plans");
if (!existsSync(plansDirectory)) {
  addError(".agent/plans does not exist");
} else if (!lstatSync(plansDirectory).isDirectory() || lstatSync(plansDirectory).isSymbolicLink()) {
  addError(".agent/plans must be a regular directory");
} else if (!insideRepository(realpathSync(plansDirectory))) {
  addError(".agent/plans must stay inside the repository");
} else {
  const planFiles = [];
  for (const entry of readdirSync(plansDirectory, { withFileTypes: true })) {
    if (entry.name === ".gitkeep" && entry.isFile()) continue;
    if (!entry.isFile() || entry.isSymbolicLink()) {
      addError(`.agent/plans/${entry.name}: only active Markdown plan files are allowed`);
      continue;
    }
    if (!entry.name.endsWith(".md")) {
      addError(`.agent/plans/${entry.name}: only active Markdown plan files are allowed`);
      continue;
    }
    planFiles.push(resolve(plansDirectory, entry.name));
  }

  if (planFiles.length > 1) addError(".agent/plans: at most one active ExecPlan is allowed");
  for (const plan of planFiles.sort()) validatePlan(plan);
}

if (errors.length > 0 || omittedErrors > 0) {
  for (const error of errors.sort()) process.stderr.write(`${error}\n`);
  if (omittedErrors > 0) process.stderr.write(`check-exec-plans: ${omittedErrors} additional errors omitted\n`);
  process.exit(1);
}

process.stdout.write("check-exec-plans: ok\n");
