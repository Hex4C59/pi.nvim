local repo_root = assert(os.getenv("PI_NVIM_COVERAGE_REPO"), "coverage repository root is required")
local stats_file = assert(os.getenv("PI_NVIM_COVERAGE_STATS"), "coverage stats path is required")
local vendor_root = repo_root .. "/scripts/vendor/luacov"

package.path = table.concat({
  vendor_root .. "/?.lua",
  vendor_root .. "/?/init.lua",
  package.path,
}, ";")

local function escape_pattern(value)
  return (value:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"))
end

local runner = require("luacov.runner")
assert(runner.version == "0.17.0", "coverage requires vendored LuaCov 0.17.0")

local root_pattern = "^" .. escape_pattern(repo_root)
runner({
  statsfile = stats_file,
  include = {
    root_pattern .. "/lua/pi/",
    root_pattern .. "/plugin/pi$",
  },
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    runner.shutdown()
  end,
})

vim.opt.runtimepath:prepend(repo_root)
