local M = {}

local function format_bytes(bytes)
  if bytes >= 1024 * 1024 then
    return ("%.1f MiB"):format(bytes / (1024 * 1024))
  elseif bytes >= 1024 then
    return ("%.1f KiB"):format(bytes / 1024)
  end
  return ("%d bytes"):format(bytes)
end

function M.check()
  vim.health.start("pi.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10 or newer")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local options = require("pi.config").get()
  local command = options.command
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

  local mode = options.security.mode
  local guards = { "session-root-guard" }
  if mode == "confirm" then
    table.insert(guards, "permission-gate")
  elseif mode == "read-only" then
    table.insert(guards, "workspace-guard")
  end
  vim.health.info("Security mode: " .. mode)
  vim.health.ok("Bundled guards: " .. table.concat(guards, ", "))
  if mode == "confirm" then
    vim.health.ok("Permission policy: Extension-owned; required confirmations fail closed")
    vim.health.info("Permission mode sync: pi.permission_mode Extension status")
  end
  if mode == "full" then
    vim.health.warn("Full mode gives model tools host-level access; only cross-project session resume remains guarded")
  end
  vim.health.info(
    ("Output limits: live %s / %d lines / %d chunks; tool %s; transcript %s; RPC queue %s / %d messages; render %d ms"):format(
      format_bytes(options.output.live_max_bytes),
      options.output.live_max_lines,
      options.output.max_chunks,
      format_bytes(options.output.tool_max_bytes),
      format_bytes(options.output.transcript_max_bytes),
      format_bytes(options.output.rpc_queue_max_bytes),
      options.output.rpc_queue_max_messages,
      options.output.render_interval_ms
    )
  )
  local image_options = options.images or {}
  local image_status = require("pi.ui.image_backend").inspect()
  vim.health.info("Inline image backend requested: " .. image_status.requested)
  vim.health.info("Inline image provider: " .. tostring(image_status.provider))
  if image_status.actual == "terminal" then
    vim.health.ok("Inline image backend active: terminal images")
  elseif image_status.actual == "blocks" then
    if image_status.requested == "terminal" then
      vim.health.warn("Terminal image provider unavailable: " .. tostring(image_status.reason or "unavailable"))
    end
    vim.health.ok("Inline image backend active: asynchronous colored-block previews")
  elseif image_status.requested == "terminal" then
    vim.health.warn("Inline image backend fell back to text: " .. tostring(image_status.reason or "unavailable"))
  else
    vim.health.info(
      "Inline image backend active: text fallback (" .. tostring(image_status.reason or "configured") .. ")"
    )
  end
  vim.health.info(
    ("Image limits: %s compressed / %d pixels / %dx%d cells; cache retention %d days"):format(
      format_bytes(image_options.max_bytes),
      image_options.max_pixels,
      image_options.max_width,
      image_options.max_height,
      image_options.cache_max_age_days
    )
  )

  if vim.fn.executable("wl-paste") == 1 or vim.fn.executable("xclip") == 1 then
    vim.health.ok("Clipboard image reader: wl-paste/xclip")
  else
    vim.health.warn("Clipboard image reader not found: install wl-clipboard or xclip")
  end
end

return M
