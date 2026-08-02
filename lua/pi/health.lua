local M = {}

function M.check()
  vim.health.start("pi.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10 or newer")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local command = require("pi.config").get().command
  if vim.fn.executable(command) == 1 then
    local result = vim.system({ command, "--version" }, { text = true }):wait(3000)
    if result.code == 0 then
      vim.health.ok("Pi executable: " .. vim.trim(result.stdout or command))
    else
      vim.health.warn("Pi executable was found but version detection failed")
    end
  else
    vim.health.error(("Pi executable not found: %s"):format(command))
  end
end

return M
