local Registry = require("pi.ui.chat.registry").Registry

local setup_count = 0
local refresh_count = 0
local layout_count = 0
local layout_options = {}
local clamp_count = 0
local mouse_cancel_count = 0
local current_window = vim.api.nvim_get_current_win()
local registry

local function run()
  registry = Registry.new({
    group_name = "PiNvimRegistrySpec",
    setup_highlights = function()
      setup_count = setup_count + 1
    end,
    refresh_preview_highlights = function()
      refresh_count = refresh_count + 1
    end,
    welcome_palette = function()
      return { "#ff0000", "#00ff00", "#0000ff", "#ffffff" }, "#000000"
    end,
  })

  registry:prepare()
  assert(setup_count == 1, "registry preparation did not initialize highlights")
  local entry = {
    is_open = function()
      return true
    end,
    layout = function(options)
      layout_count = layout_count + 1
      table.insert(layout_options, options)
    end,
    window = function()
      return current_window
    end,
    clamp = function()
      clamp_count = clamp_count + 1
    end,
    clear_images = function() end,
    cancel_mouse = function()
      mouse_cancel_count = mouse_cancel_count + 1
    end,
  }
  registry:register("registry-project", entry)

  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(setup_count == 2 and refresh_count == 1, "registry did not own colorscheme refresh")
  vim.api.nvim_exec_autocmds("VimResized", {})
  vim.api.nvim_exec_autocmds("WinResized", {})
  assert(layout_count == 2, "registry did not route resize to the open Chat")
  assert(
    layout_options[1].global_resize == true and layout_options[2].global_resize == false,
    "registry did not distinguish global and local resize"
  )
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(current_window) })
  assert(clamp_count == 1, "registry did not clamp the scrolled Chat window")
  vim.api.nvim_exec_autocmds("WinClosed", { pattern = tostring(current_window) })
  assert(mouse_cancel_count == 1, "registry did not clear mouse state for a closed Chat window")

  registry:sync_welcome_animation()
  assert(registry.welcome_animation_timer ~= nil, "registry did not own the shared welcome timer")
  registry:unregister("registry-project")
  assert(registry.welcome_animation_timer == nil, "registry retained the welcome timer without an open Chat")

  local group = registry.group
  registry:destroy()
  registry:destroy()
  assert(not pcall(vim.api.nvim_get_autocmds, { group = group }), "registry autocmd group survived destroy")
end

local ok, err = xpcall(run, debug.traceback)
if registry then
  pcall(registry.destroy, registry)
end
if not ok then
  error(err)
end

print("chat_registry_spec: ok")
