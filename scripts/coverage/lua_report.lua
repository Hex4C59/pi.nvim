local repo_root = assert(os.getenv("PI_NVIM_COVERAGE_REPO"), "coverage repository root is required")
local merged_file = assert(os.getenv("PI_NVIM_COVERAGE_MERGED"), "merged stats path is required")
local report_file = assert(os.getenv("PI_NVIM_COVERAGE_REPORT"), "coverage report path is required")
local vendor_root = repo_root .. "/scripts/vendor/luacov"

package.path = table.concat({
  vendor_root .. "/?.lua",
  vendor_root .. "/?/init.lua",
  package.path,
}, ";")

local runner = require("luacov.runner")
local reporter = require("luacov.reporter")
local ReporterBase = reporter.ReporterBase
local SummaryReporter = setmetatable({}, ReporterBase)
SummaryReporter.__index = SummaryReporter

local function percentage(hits, missed)
  local total = hits + missed
  if total == 0 then
    return "0.00%"
  end

  local hundredths = math.floor((hits * 10000 + total / 2) / total)
  return ("%d.%02d%%"):format(math.floor(hundredths / 100), hundredths % 100)
end

local function write_table(instance, rows)
  local widths = {}
  for _, row in ipairs(rows) do
    for column, value in ipairs(row) do
      widths[column] = math.max(widths[column] or 0, #value)
    end
  end

  for row_number, row in ipairs(rows) do
    if row_number == 2 or row_number == #rows then
      local width = #widths - 1
      for _, column_width in ipairs(widths) do
        width = width + column_width
      end
      instance:write(("-"):rep(width), "\n")
    end

    for column, value in ipairs(row) do
      instance:write(value)
      if column == #row then
        instance:write("\n")
      else
        instance:write((" "):rep(widths[column] - #value + 1))
      end
    end
  end
end

function SummaryReporter:on_start()
  self._summary = {}
end

function SummaryReporter:on_file_error(filename, error_type, message)
  error(("could not %s %s: %s"):format(error_type, filename, message))
end

function SummaryReporter:on_end_file(filename, hits, missed)
  self._summary[filename] = { hits = hits, missed = missed }
end

function SummaryReporter:on_end()
  self:write("Lua coverage (LuaCov 0.17.0)\n")
  self:write("Included: lua/pi/**/*.lua, plugin/pi.lua\n")
  self:write("Excluded: tests, fixtures, vendored tooling, generated data\n\n")

  local rows = { { "File", "Hits", "Missed", "Lines" } }
  local total_hits = 0
  local total_missed = 0

  for _, filename in ipairs(self:files()) do
    local summary = assert(self._summary[filename], "missing summary for " .. filename)
    total_hits = total_hits + summary.hits
    total_missed = total_missed + summary.missed
    rows[#rows + 1] = {
      filename,
      tostring(summary.hits),
      tostring(summary.missed),
      percentage(summary.hits, summary.missed),
    }
  end

  rows[#rows + 1] = {
    "Total",
    tostring(total_hits),
    tostring(total_missed),
    percentage(total_hits, total_missed),
  }
  write_table(self, rows)
end

assert(runner.version == "0.17.0", "coverage requires vendored LuaCov 0.17.0")
runner.load_config({
  statsfile = merged_file,
  reportfile = report_file,
  include = {
    "^lua/pi/",
    "^plugin/pi$",
  },
})
reporter.report(SummaryReporter)
print("coverage lua: wrote " .. report_file)
