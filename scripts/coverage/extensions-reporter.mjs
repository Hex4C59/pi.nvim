import { readdirSync, writeFileSync } from "node:fs";
import { relative, resolve, sep } from "node:path";
import { Readable } from "node:stream";
import { spec } from "node:test/reporters";

const repoRoot = resolve(
  process.env.PI_NVIM_COVERAGE_REPO ?? process.cwd(),
);
const sourceRoot = resolve(repoRoot, "extensions", "lib");
const reportPath = process.env.PI_NVIM_EXTENSION_COVERAGE_REPORT;

if (!reportPath) {
  throw new Error("PI_NVIM_EXTENSION_COVERAGE_REPORT is required");
}

function discoverSources(directory) {
  const sources = [];

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      sources.push(...discoverSources(path));
    } else if (entry.isFile() && entry.name.endsWith(".mjs")) {
      sources.push(path);
    }
  }

  return sources.sort();
}

function isOwnedSource(path) {
  const sourceRelative = relative(sourceRoot, resolve(path));
  return (
    sourceRelative !== "" &&
    sourceRelative !== ".." &&
    !sourceRelative.startsWith(`..${sep}`) &&
    sourceRelative.endsWith(".mjs")
  );
}

function percent(covered, total) {
  return total === 0 ? "n/a" : `${((covered / total) * 100).toFixed(2)}%`;
}

function table(rows) {
  const widths = rows[0].map((_, column) =>
    Math.max(...rows.map((row) => row[column].length)),
  );
  const separator = widths.map((width) => "-".repeat(width)).join(" ");

  return rows
    .flatMap((row, index) => {
      const line = row
        .map((value, column) => value.padEnd(widths[column]))
        .join(" ")
        .trimEnd();
      return index === 1 || index === rows.length - 1
        ? [separator, line]
        : [line];
    })
    .join("\n");
}

function makeSummary(event) {
  const expectedSources = discoverSources(sourceRoot);
  const coveredFiles = new Map(
    event.data.summary.files
      .filter((file) => isOwnedSource(file.path))
      .map((file) => [resolve(file.path), file]),
  );
  const rows = [["File", "Lines", "Branches", "Functions"]];
  const totals = {
    coveredLineCount: 0,
    totalLineCount: 0,
    coveredBranchCount: 0,
    totalBranchCount: 0,
    coveredFunctionCount: 0,
    totalFunctionCount: 0,
  };

  for (const source of expectedSources) {
    const file = coveredFiles.get(source);
    const displayPath = relative(repoRoot, source).split(sep).join("/");

    if (!file) {
      rows.push([displayPath, "not loaded", "not loaded", "not loaded"]);
      continue;
    }

    rows.push([
      displayPath,
      percent(file.coveredLineCount, file.totalLineCount),
      percent(file.coveredBranchCount, file.totalBranchCount),
      percent(file.coveredFunctionCount, file.totalFunctionCount),
    ]);

    for (const key of Object.keys(totals)) {
      totals[key] += file[key];
    }
  }

  rows.push([
    "Total",
    percent(totals.coveredLineCount, totals.totalLineCount),
    percent(totals.coveredBranchCount, totals.totalBranchCount),
    percent(totals.coveredFunctionCount, totals.totalFunctionCount),
  ]);

  return [
    "Extension coverage (Node built-in test coverage)",
    "Included: extensions/lib/**/*.mjs",
    "Excluded: extensions/*.ts, tests, Node internals, global Pi, generated cache",
    "",
    table(rows),
  ].join("\n");
}

async function* sourceOnlyCoverage(source) {
  for await (const event of source) {
    if (event.type !== "test:coverage") {
      yield event;
      continue;
    }

    const summary = makeSummary(event);
    writeFileSync(reportPath, `${summary}\n`, "utf8");
    yield {
      type: "test:diagnostic",
      data: {
        nesting: event.data.nesting ?? 0,
        message: `\n${summary}`,
      },
    };
  }
}

export default async function* extensionsReporter(source) {
  yield* Readable.from(sourceOnlyCoverage(source)).pipe(new spec());
}
