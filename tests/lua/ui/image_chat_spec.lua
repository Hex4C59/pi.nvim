local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat

local chats = {}

local function track_chat(root)
  local chat = Chat.new(root)
  table.insert(chats, chat)
  return chat
end

local root = vim.fn.getcwd()
local image = {
  type = "image",
  mimeType = "image/png",
  data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
}

config.setup({ images = { backend = "text", max_width = 32, max_height = 16 } })

local function run()
  local chat = track_chat(root)
  assert(chat:add_image_attachment(image), "image attachment was rejected")
  assert(#chat.pending_images == 1, "image attachment was not queued")
  local taken = chat:take_image_attachments()
  assert(#taken == 1 and taken[1] == image, "image attachment queue did not drain")

  local captured
  local clear_calls = 0
  local sync_calls = 0
  chat.image_backend = {
    is_terminal = function()
      return true
    end,
    sync = function(_, buf, win, selected)
      assert(vim.api.nvim_buf_is_valid(buf), "Chat synced images before writing a valid buffer")
      assert(win and vim.api.nvim_win_is_valid(win), "Chat did not pass its transcript window")
      captured = vim.deepcopy(selected)
      sync_calls = sync_calls + 1
      return true
    end,
    clear = function()
      clear_calls = clear_calls + 1
    end,
  }
  chat:open(false)
  chat:add_user("", { image })
  assert(
    chat.transcript.items[#chat.transcript.items].content[1].data == nil,
    "accepted user image retained Base64 in the Chat projection"
  )
  assert(
    chat.transcript.items[#chat.transcript.items].content[1].path,
    "accepted user image did not retain a local cache path"
  )
  assert(image.data, "localizing an accepted image mutated the original RPC payload")
  assert(captured and #captured == 1, "Chat did not sync rendered image placements")
  local inline_placement = chat.transcript_view.image_placements[1]
  local inline_width = inline_placement.width
  local screen_position = vim.fn.screenpos(chat.win, inline_placement.row + 1, inline_placement.col + 1)
  assert(screen_position.row > 0, "image click fixture is not visible")
  assert(
    chat:_handle_left_mouse({
      winid = chat.win,
      line = inline_placement.row + 1,
      column = inline_placement.col + 1,
      screenrow = screen_position.row,
      screencol = screen_position.col,
    }),
    "clicking a rendered image was not handled"
  )
  assert(
    chat.image_preview.win and vim.api.nvim_win_is_valid(chat.image_preview.win),
    "clicking an image did not open the preview"
  )
  assert(captured[1].inline == false, "enlarged image reused inline placement mode")
  assert(captured[1].width > inline_width, "enlarged image did not use the available editor width")
  local has_keyboard_preview = false
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(chat.transcript_view.buf, "n")) do
    has_keyboard_preview = has_keyboard_preview or mapping.lhs == "<CR>"
  end
  assert(has_keyboard_preview, "image preview is not accessible from the keyboard")
  chat:_close_image_preview()
  assert(
    not chat.image_preview.win and not chat.image_preview.buf,
    "image preview did not release its window and buffer"
  )
  assert(chat:_open_image_preview(inline_placement), "image preview could not be reopened")
  local preview_buf = chat.image_preview.buf
  vim.api.nvim_buf_delete(preview_buf, { force = true })
  assert(not chat.image_preview.win and not chat.image_preview.buf, "wiping the preview buffer left stale UI state")
  chat:close()
  assert(clear_calls >= 1, "Chat close did not clear image handles")
  local before_reopen = sync_calls
  chat:open(false)
  assert(sync_calls > before_reopen, "Chat reopen did not rebuild image placements")
  chat:set_position("bottom")
  assert(sync_calls > before_reopen + 1, "layout switch did not rebuild image placements")
  chat:close()

  local wipe_chat = track_chat(root .. "/wipe")
  local wipe_clears = 0
  wipe_chat.image_backend = {
    is_terminal = function()
      return false
    end,
    sync = function() end,
    clear = function()
      wipe_clears = wipe_clears + 1
    end,
  }
  wipe_chat:open(false)
  local wiped = wipe_chat.transcript_view.buf
  vim.api.nvim_buf_delete(wiped, { force = true })
  assert(wipe_clears >= 1, "Buffer wipe did not clear image handles")
  wipe_chat:close()

  local input_chat = track_chat(root .. "/input")
  input_chat:open(false)
  local input_maps = vim.api.nvim_buf_get_keymap(input_chat.input_area:buffer(), "i")
  local has_paste_map = false
  for _, mapping in ipairs(input_maps) do
    has_paste_map = has_paste_map or mapping.lhs == "<C-V>" or mapping.lhs == "<C-S-V>"
  end
  assert(has_paste_map, "prompt is missing the clipboard image paste shortcut")
  input_chat:close()

  config.setup({
    images = {
      backend = "text",
      attachment_max_count = 2,
      attachment_max_bytes = 1024,
    },
  })
  local attachment_chat = track_chat(root .. "/attachment-limits")
  local first_attachment = { type = "image", mimeType = "image/png", data = string.rep("a", 500) }
  local second_attachment = { type = "image", mimeType = "image/png", data = string.rep("b", 500) }
  assert(attachment_chat:add_image_attachment(first_attachment), "first bounded attachment was rejected")
  assert(attachment_chat:add_image_attachment(second_attachment), "second bounded attachment was rejected")
  local added, count_err = attachment_chat:add_image_attachment(image)
  assert(not added and count_err:find("Too many", 1, true), "attachment count limit was not enforced")
  attachment_chat:take_image_attachments()
  assert(attachment_chat:add_image_attachment(first_attachment), "attachment byte fixture was rejected too early")
  local restored, byte_err =
    attachment_chat:restore_image_attachments({ { type = "image", data = string.rep("c", 600) } })
  assert(not restored and byte_err:find("too large", 1, true), "aggregate attachment byte limit was not enforced")
  assert(#attachment_chat.pending_images == 1, "failed attachment restore partially mutated the pending list")
  attachment_chat:destroy()
end

local ok, err = xpcall(run, debug.traceback)
for index = #chats, 1, -1 do
  pcall(chats[index].destroy, chats[index])
end
if not ok then
  error(err)
end

print("image_chat_spec: ok")
