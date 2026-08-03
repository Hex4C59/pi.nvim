local config = require("pi.config")
local image = require("pi.ui.image")

local M = {}
local Backend = {}
Backend.__index = Backend

local last_status

local function fallback_backend(requested)
  if requested ~= "text" and vim.fn.executable("magick") == 1 then
    return "blocks"
  end
  return "text"
end

local function configured()
  local options = config.get().images or {}
  return options, options.terminal or {}
end

local function default_adapter(terminal)
  if terminal.provider ~= "snacks" then
    return nil, "unknown terminal image provider: " .. tostring(terminal.provider)
  end
  local Adapter = require("pi.ui.image.backends.snacks")
  return Adapter.new(terminal)
end

function Backend:_publish()
  last_status = self:status()
end

function Backend:_transition(state, reason)
  local changed = self.state ~= state or self.reason ~= reason
  self.state = state
  self.reason = reason
  self:_publish()
  if changed and self.on_change then
    self.on_change()
  end
end

function Backend.new(opts)
  opts = opts or {}
  local images, terminal = configured()
  local self = setmetatable({
    requested = opts.requested or images.backend or "auto",
    provider = terminal.provider or "snacks",
    state = "text",
    reason = nil,
    adapter = opts.adapter,
    on_change = opts.on_change,
  }, Backend)

  if self.requested == "text" then
    self.reason = "terminal images are disabled by configuration"
    self:_publish()
    return self
  end
  if not self.adapter then
    self.adapter, self.reason = default_adapter(terminal)
  end
  if not self.adapter then
    self.state = "unavailable"
    self:_publish()
    return self
  end

  self.state = "probing"
  self:_publish()
  local ok, probe_err = pcall(self.adapter.probe, self.adapter, function(available, reason)
    self:_transition(available and "available" or "unavailable", reason)
  end)
  if not ok then
    self:_transition("failed", "terminal image probe failed: " .. tostring(probe_err))
  end
  return self
end

function Backend:is_terminal()
  return self.state == "available"
end

function Backend:sync(buf, win, placements)
  if
    not buf
    or not vim.api.nvim_buf_is_valid(buf)
    or not win
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_win_get_buf(win) ~= buf
  then
    if self.adapter then
      pcall(self.adapter.clear, self.adapter, buf)
    end
    return false
  end
  if not self:is_terminal() then
    if self.adapter then
      pcall(self.adapter.clear, self.adapter, buf)
    end
    return false
  end
  local failed = false
  local ok, result, sync_err = pcall(self.adapter.sync, self.adapter, buf, win, placements, function(descriptor, reason)
    failed = true
    image.fail_backend(descriptor.block, reason)
    if self.on_change then
      self.on_change()
    end
  end)
  if not ok or result == false then
    local reason = ok and sync_err or result
    pcall(self.adapter.clear, self.adapter, buf)
    self:_transition("failed", "terminal image backend failed: " .. tostring(reason))
    return false
  end
  return not failed
end

function Backend:clear(buf)
  if self.adapter then
    pcall(self.adapter.clear, self.adapter, buf)
  end
end

function Backend:status()
  return {
    requested = self.requested,
    provider = self.provider,
    state = self.state,
    actual = self:is_terminal() and "terminal" or fallback_backend(self.requested),
    reason = self.reason,
  }
end

function M.new(opts)
  return Backend.new(opts)
end

function M.inspect()
  local images, terminal = configured()
  if last_status and last_status.requested == images.backend and last_status.provider == terminal.provider then
    return vim.deepcopy(last_status)
  end
  if images.backend == "text" then
    return {
      requested = "text",
      provider = terminal.provider,
      state = "text",
      actual = fallback_backend(images.backend),
      reason = "terminal images are disabled by configuration",
    }
  end
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return {
      requested = images.backend,
      provider = terminal.provider,
      state = "unavailable",
      actual = fallback_backend(images.backend),
      reason = "snacks.nvim is not installed",
    }
  end
  if not (snacks.config and snacks.config.image and snacks.config.image.enabled == true) then
    return {
      requested = images.backend,
      provider = terminal.provider,
      state = "unavailable",
      actual = fallback_backend(images.backend),
      reason = "snacks.image is not enabled",
    }
  end
  local image_ok, terminal_supported = pcall(function()
    return snacks.image.supports_terminal()
  end)
  return {
    requested = images.backend,
    provider = terminal.provider,
    state = image_ok and terminal_supported and "available" or "unavailable",
    actual = image_ok and terminal_supported and "terminal" or fallback_backend(images.backend),
    reason = image_ok and terminal_supported and nil or "the current terminal does not support Kitty graphics",
  }
end

M.Backend = Backend
return M
