local InputArea = require("pi.ui.input").InputArea

local group = vim.api.nvim_create_augroup("PiNvimInputSpec", { clear = true })
local calls = { layout = 0, close_command_menu = 0 }
local function noop() end
local state = {
  active = false,
  activity = "idle",
  activity_text = "Thinking",
  animation_frame = 0,
  stats = { contextUsage = { percent = 42 } },
  queue = { steering = {}, followUp = {} },
  permission_mode = "manual",
  permission_mode_label = "Manual",
  model = "fixture-model",
  thinking = "high",
  pending_image_count = 0,
}
local actions = {
  layout = function()
    calls.layout = calls.layout + 1
  end,
  close_command_menu = function()
    calls.close_command_menu = calls.close_command_menu + 1
  end,
  update_command_menu = function()
    return false
  end,
  command_menu_visible = function()
    return false
  end,
  select_command = function()
    return false
  end,
  accept_command_completion = function()
    return false
  end,
  take_image_attachments = function()
    return {}
  end,
  add_image_attachment = function()
    return false
  end,
  submit = noop,
  abort = noop,
  select_model = noop,
  cycle_model = noop,
  cycle_permission_mode = noop,
  cycle_thinking_level = noop,
  close = noop,
  toggle_tools = noop,
  toggle_thinking = noop,
  copy_last_assistant = noop,
  left_mouse = function()
    return false
  end,
}
local input = InputArea.new({
  root = vim.fs.joinpath(vim.fn.getcwd(), "input-project"),
  namespace = vim.api.nvim_create_namespace("pi.nvim.input.spec"),
  ui_group = group,
  state = function()
    return state
  end,
  main_window = function()
    return nil
  end,
  actions = actions,
})

local input_buffer = input:ensure_input_buffer()
local status_buffer = input:ensure_status_buffer()
assert(input:owns_buffer(input_buffer) and input:owns_buffer(status_buffer), "InputArea did not own its buffers")
assert(vim.b[input_buffer].pi_root:find("input-project", 1, true), "InputArea lost its immutable root dependency")
input:set_input("first\nsecond")
assert(calls.close_command_menu == 1, "InputArea did not use its injected menu-close action")
assert(input:desired_input_height() == 4, "InputArea did not size independently from Chat")
local status = input:status_text(80)
assert(status[1]:find("fixture-model", 1, true), "InputArea did not render injected state")

input:destroy()
input:destroy()
assert(not vim.api.nvim_buf_is_valid(input_buffer), "InputArea input buffer survived destroy")
assert(not vim.api.nvim_buf_is_valid(status_buffer), "InputArea status buffer survived destroy")
pcall(vim.api.nvim_del_augroup_by_id, group)

print("input_spec: ok")
