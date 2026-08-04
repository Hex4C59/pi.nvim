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

local function attachment_text(chat)
  local buf = chat.input_area:ensure_input_buffer()
  local tokens = {}
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local chunks = (extmark[4] or {}).virt_text
    if chunks then
      local parts = {}
      for _, chunk in ipairs(chunks) do
        table.insert(parts, chunk[1])
      end
      local text = table.concat(parts)
      if text:find("image", 1, true) then
        table.insert(tokens, text)
      end
    end
  end
  return #tokens > 0 and table.concat(tokens) or nil
end

config.setup({ images = { backend = "text", max_width = 32, max_height = 16 } })

local function run()
  local chat = track_chat(root)
  assert(chat:add_image_attachment(image), "image attachment was rejected")
  assert(#chat.pending_attachments == 1, "image attachment was not queued")
  local taken = chat:take_image_attachments()
  assert(#taken == 1 and taken[1] == image, "image attachment queue did not drain")

  local removal_chat = track_chat(root .. "/attachment-removal")
  local attachments = {}
  for index = 1, 4 do
    attachments[index] = vim.tbl_extend("force", {}, image, { fixture_index = index })
    assert(removal_chat:add_image_attachment(attachments[index]), "removal fixture attachment was rejected")
  end
  assert(
    attachment_text(removal_chat) == "[image 1] [image 2] [image 3] [image 4]",
    "pending attachment projection did not show each image token"
  )
  assert(removal_chat:remove_image_attachment(removal_chat:attachment_ids()[1]), "first attachment was not removed")
  assert(
    vim.deep_equal(removal_chat:pending_images(), { attachments[2], attachments[3], attachments[4] }),
    "removing the first attachment changed the remaining order"
  )
  assert(attachment_text(removal_chat) == "[image 1] [image 2] [image 3]", "first removal did not refresh the prompt")
  local snapshot = removal_chat:pending_images()
  for _, invalid in ipairs({ 0, 1.5, 1, "1" }) do
    assert(not removal_chat:remove_image_attachment(invalid), "invalid attachment index was accepted")
    assert(vim.deep_equal(removal_chat:pending_images(), snapshot), "invalid removal changed pending attachments")
  end
  assert(removal_chat:remove_image_attachment(removal_chat:attachment_ids()[2]), "middle attachment was not removed")
  assert(
    vim.deep_equal(removal_chat:pending_images(), { attachments[2], attachments[4] }),
    "removing the middle attachment changed the remaining order"
  )
  assert(attachment_text(removal_chat) == "[image 1] [image 2]", "middle removal did not refresh the prompt")
  assert(removal_chat:remove_image_attachment(removal_chat:attachment_ids()[2]), "last attachment was not removed")
  assert(
    #removal_chat.pending_attachments == 1 and removal_chat:pending_images()[1] == attachments[2],
    "removing the last attachment changed the retained item"
  )
  assert(attachment_text(removal_chat) == "[1 image attached]", "last removal did not restore the single-image token")

  local ordered_chat = track_chat(root .. "/ordered-draft")
  local ordered_images = {}
  for index = 1, 3 do
    ordered_images[index] = vim.tbl_extend("force", {}, image, { fixture_index = index })
    assert(ordered_chat:add_image_attachment(ordered_images[index]), "ordered attachment was rejected")
  end
  ordered_chat:open(false)
  ordered_chat:set_input("before")
  ordered_chat.input_area:_select_attachment(1)
  ordered_chat.input_area:_insert_text_at_cursor("between-one")
  ordered_chat.input_area:_select_attachment(2)
  ordered_chat.input_area:_insert_text_at_cursor("between-two")
  ordered_chat.input_area:_select_attachment(3)
  ordered_chat.input_area:_insert_text_at_cursor("after")
  local submission = ordered_chat:take_prompt_draft(ordered_chat.input_area:content_parts())
  assert(
    vim.deep_equal(submission.content, {
      { type = "text", text = "before" },
      ordered_images[1],
      { type = "text", text = "between-one" },
      ordered_images[2],
      { type = "text", text = "between-two" },
      ordered_images[3],
      { type = "text", text = "after" },
    }),
    "Chat did not resolve attachment slots into ordered prompt content: " .. vim.inspect(submission.content)
  )
  ordered_chat.input_area:set_input("")
  assert(ordered_chat:restore_prompt_draft(submission.draft), "ordered prompt draft was not restored")
  local restored_tokens = vim.trim((attachment_text(ordered_chat) or ""):gsub("%s+", " "))
  assert(
    restored_tokens == "[image 1] [image 2] [image 3]",
    "restored ordered draft lost attachment token projection: " .. restored_tokens
  )
  assert(
    ordered_chat.input_area:content_parts()[3].text == "between-one"
      and ordered_chat.input_area:content_parts()[5].text == "between-two"
      and ordered_chat.input_area:content_parts()[7].text == "after",
    "restored ordered draft lost text around attachments"
  )

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
  assert(captured and #captured == 0, "Chat sent a user attachment token to the terminal image backend")
  local inline_placement = chat.transcript_view.image_placements[1]
  assert(inline_placement.token, "accepted user image did not render as an attachment token")
  local inline_width = inline_placement.width
  assert(not chat:_handle_left_mouse({
    winid = chat.win,
    line = inline_placement.row + 1,
    column = math.max(1, inline_placement.col),
  }), "clicking beside a user attachment token opened its preview")
  assert(
    chat:_handle_left_mouse({
      winid = chat.win,
      line = inline_placement.row + 1,
      column = inline_placement.col + 1,
    }),
    "exact user attachment token click was not handled"
  )
  assert(
    chat.image_preview.win and vim.api.nvim_win_is_valid(chat.image_preview.win),
    "clicking an image did not open the preview"
  )
  assert(captured and #captured == 1 and captured[1].inline == false, "enlarged image reused inline placement mode")
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
  assert(#attachment_chat.pending_attachments == 1, "failed attachment restore partially mutated the pending list")
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
