local repo_root = assert(os.getenv("PI_NVIM_COVERAGE_REPO"), "coverage repository root is required")
local raw_root = assert(os.getenv("PI_NVIM_COVERAGE_RAW_ROOT"), "coverage raw root is required")
local stats_manifest = assert(os.getenv("PI_NVIM_COVERAGE_STATS_MANIFEST"), "stats manifest is required")
local source_manifest = assert(os.getenv("PI_NVIM_COVERAGE_SOURCE_MANIFEST"), "source manifest is required")
local merged_file = assert(os.getenv("PI_NVIM_COVERAGE_MERGED"), "merged stats path is required")
local vendor_root = repo_root .. "/scripts/vendor/luacov"

package.path = table.concat({
  vendor_root .. "/?.lua",
  vendor_root .. "/?/init.lua",
  package.path,
}, ";")

local runner = require("luacov.runner")
local stats = require("luacov.stats")
local uv = vim.uv or vim.loop

assert(runner.version == "0.17.0", "coverage requires vendored LuaCov 0.17.0")

local function read_manifest(path, description)
  local handle = assert(io.open(path, "r"))
  local entries = {}

  for line in handle:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" then
      entries[#entries + 1] = line
    end
  end

  handle:close()
  assert(#entries > 0, description .. " manifest is empty")
  return entries
end

local function is_source_path(path)
  return path:match("^lua/pi/.+%.lua$") ~= nil or path == "plugin/pi.lua"
end

local normalized_root = repo_root:gsub("\\", "/"):gsub("/$", "")
local function normalize_source_path(path)
  local normalized = path:gsub("\\", "/"):gsub("^@", ""):gsub("^%./", "")
  local prefix = normalized_root .. "/"

  if normalized:sub(1, #prefix) == prefix then
    normalized = normalized:sub(#prefix + 1)
  end

  assert(is_source_path(normalized), "unexpected Lua coverage source: " .. normalized)
  return normalized
end

local merged = {}
local seen_artifacts = {}
local artifacts = read_manifest(stats_manifest, "stats")
local raw_prefix = raw_root:gsub("/$", "") .. "/"

for _, artifact in ipairs(artifacts) do
  assert(not seen_artifacts[artifact], "duplicate stats artifact: " .. artifact)
  seen_artifacts[artifact] = true

  local metadata = uv.fs_lstat(artifact)
  assert(metadata and metadata.type == "file", "stats artifact is not a regular file: " .. artifact)
  assert(artifact:sub(1, #raw_prefix) == raw_prefix, "stats artifact is outside the current raw directory")

  local artifact_stats = assert(stats.load(artifact), "could not read stats artifact: " .. artifact)
  for filename, file_stats in pairs(artifact_stats) do
    local normalized = normalize_source_path(filename)
    if merged[normalized] then
      runner.update_stats(merged[normalized], file_stats)
    else
      merged[normalized] = file_stats
    end
  end
end

local seen_sources = {}
for _, source in ipairs(read_manifest(source_manifest, "source")) do
  local normalized = normalize_source_path(source)
  assert(not seen_sources[normalized], "duplicate source path: " .. normalized)
  seen_sources[normalized] = true

  local metadata = uv.fs_lstat(repo_root .. "/" .. normalized)
  assert(metadata and metadata.type == "file", "coverage source is not a regular file: " .. normalized)

  if not merged[normalized] then
    merged[normalized] = { max = 0, max_hits = 0 }
  end
end

for source in pairs(merged) do
  assert(seen_sources[source], "collected source is absent from the current source manifest: " .. source)
end

stats.save(merged_file, merged)
print(
  ("coverage lua: merged %d fresh process artifacts across %d source files"):format(#artifacts, vim.tbl_count(merged))
)
