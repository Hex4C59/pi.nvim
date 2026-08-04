local highlights = require("pi.ui.highlights")
local image_data = require("pi.ui.image")

local M = {}
local Registry = {}
Registry.__index = Registry

function Registry.new(opts)
  opts = opts or {}
  local self = setmetatable({
    namespace = opts.namespace or vim.api.nvim_create_namespace("pi.nvim"),
    instances = setmetatable({}, { __mode = "v" }),
    welcome_animation_timer = nil,
    welcome_animation_frame = 0,
    setup_highlights = opts.setup_highlights or highlights.setup,
    refresh_preview_highlights = opts.refresh_preview_highlights or image_data.refresh_preview_highlights,
    welcome_palette = opts.welcome_palette or highlights.welcome_palette,
    group = vim.api.nvim_create_augroup(opts.group_name or "PiNvimUI", { clear = true }),
    destroyed = false,
  }, Registry)
  self:_register_autocmds()
  return self
end

function Registry:_update_welcome_logo_highlights()
  local palette, background = self.welcome_palette()
  if #palette == 0 then
    return
  end
  for index = 1, 4 do
    local palette_index = (index + self.welcome_animation_frame - 2) % #palette + 1
    vim.api.nvim_set_hl(0, "PiWelcomeLogo" .. index, {
      fg = palette[palette_index],
      bg = background,
      bold = true,
    })
  end
end

function Registry:_has_open_chat()
  for _, entry in pairs(self.instances) do
    if entry.is_open() then
      return true
    end
  end
  return false
end

function Registry:_stop_welcome_animation()
  if self.welcome_animation_timer then
    self.welcome_animation_timer:stop()
    self.welcome_animation_timer:close()
    self.welcome_animation_timer = nil
  end
end

function Registry:sync_welcome_animation()
  if self.destroyed or not self:_has_open_chat() then
    self:_stop_welcome_animation()
    return
  end
  if self.welcome_animation_timer then
    return
  end
  self.welcome_animation_timer = vim.uv.new_timer()
  self.welcome_animation_timer:start(
    360,
    360,
    vim.schedule_wrap(function()
      if self.destroyed or not self:_has_open_chat() then
        self:_stop_welcome_animation()
        return
      end
      local palette = self.welcome_palette()
      self.welcome_animation_frame = (self.welcome_animation_frame + 1) % math.max(1, #palette)
      self:_update_welcome_logo_highlights()
    end)
  )
end

function Registry:_register_autocmds()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.group,
    callback = function()
      self.setup_highlights()
      self.refresh_preview_highlights()
      self:_update_welcome_logo_highlights()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.group,
    callback = function()
      for _, entry in pairs(self.instances) do
        if entry.is_open() then
          entry.layout({ global_resize = true })
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = self.group,
    callback = function()
      for _, entry in pairs(self.instances) do
        if entry.is_open() then
          entry.layout({ global_resize = false })
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = self.group,
    callback = function(event)
      local win = tonumber(event.match)
      for _, entry in pairs(self.instances) do
        if entry.window() == win then
          entry.clamp()
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(event)
      local win = tonumber(event.match)
      for _, entry in pairs(self.instances) do
        if entry.window() == win then
          if type(entry.cancel_mouse) == "function" then
            entry.cancel_mouse()
          end
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = self.group,
    callback = function()
      self:_stop_welcome_animation()
      for _, entry in pairs(self.instances) do
        entry.clear_images()
      end
    end,
  })
end

function Registry:prepare()
  self.setup_highlights()
  self:_update_welcome_logo_highlights()
end

function Registry:register(root, entry)
  assert(type(root) == "string" and root ~= "", "Chat registry root is required")
  assert(type(entry) == "table", "Chat registry entry is required")
  self.instances[root] = entry
end

function Registry:unregister(root)
  self.instances[root] = nil
  self:sync_welcome_animation()
end

function Registry:destroy()
  if self.destroyed then
    return
  end
  self.destroyed = true
  self:_stop_welcome_animation()
  self.instances = setmetatable({}, { __mode = "v" })
  pcall(vim.api.nvim_del_augroup_by_id, self.group)
end

local default_registry

function M.default()
  if not default_registry then
    default_registry = Registry.new()
  end
  return default_registry
end

M.Registry = Registry
return M
