local config = require("pi.config")
local renderer = require("pi.ui.render")
local Chat = require("pi.ui.chat").Chat
local image_data = require("pi.ui.image")
local markdown_image = require("pi.ui.markdown_image")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

config.setup({
  images = {
    backend = "text",
    max_bytes = 2 * 1024 * 1024,
    max_width = 32,
    max_height = 16,
  },
})

local markdown_root = vim.fn.tempname()
assert(vim.fn.mkdir(markdown_root, "p") == 1, "markdown image workspace was not created")
local markdown_path = vim.fs.joinpath(markdown_root, "demo image.png")
local markdown_bytes = vim.base64.decode(png_base64)
local markdown_fd = assert(vim.uv.fs_open(markdown_path, "w", 384))
assert(vim.uv.fs_write(markdown_fd, markdown_bytes, 0) == #markdown_bytes)
vim.uv.fs_close(markdown_fd)

local markdown_text = {
  type = "text",
  text = "Before\n\n![Demo](<demo%20image.png>)\n\n```markdown\n![Literal](demo.png)\n```\n\nAfter",
}
local markdown_blocks = markdown_image.blocks(markdown_text, markdown_root)
assert(#markdown_blocks == 1, "standalone workspace Markdown image was not discovered exactly once")
assert(markdown_blocks[1].path == vim.uv.fs_realpath(markdown_path), "Markdown image path was not canonicalized")
assert(markdown_image.blocks(markdown_text, markdown_root)[1] == markdown_blocks[1], "Markdown image cache is unstable")
assert(
  not markdown_image._parse_line("![Remote](https://example.com/demo.png)", markdown_root),
  "remote Markdown image must not trigger a client fetch"
)

local outside_path = vim.fn.tempname() .. ".png"
local outside_fd = assert(vim.uv.fs_open(outside_path, "w", 384))
assert(vim.uv.fs_write(outside_fd, markdown_bytes, 0) == #markdown_bytes)
vim.uv.fs_close(outside_fd)
assert(
  not markdown_image._parse_line(("![Outside](%s)"):format(outside_path), markdown_root),
  "outside-workspace Markdown image was accepted"
)
local symlink_path = vim.fs.joinpath(markdown_root, "escape.png")
assert(vim.uv.fs_symlink(outside_path, symlink_path), "markdown image symlink fixture was not created")
assert(
  not markdown_image._parse_line("![Escape](escape.png)", markdown_root),
  "Markdown image symlink escaped the workspace"
)

assert(image_data.prepare(markdown_blocks[1], 32), "workspace Markdown image was not prepared")
local markdown_assistant = {
  type = "assistant",
  _pi_id = "assistant:markdown",
  message = { content = { markdown_text } },
}
local markdown_lines, _, _, _, markdown_placements = renderer.render({ markdown_assistant }, {
  width = 40,
  root = markdown_root,
  image_terminal = true,
  tools_expanded = true,
})
local markdown_rendered = table.concat(markdown_lines, "\n")
assert(#markdown_placements == 1, "Markdown image did not produce a terminal placement")
assert(
  markdown_rendered:find("Before", 1, true) and markdown_rendered:find("After", 1, true),
  "image hid adjacent text"
)
assert(not markdown_rendered:find("!Demo", 1, true), "Markdown image syntax leaked into the transcript")

local linked_text = {
  type = "text",
  text = "文件位置: [content-area-image-test.png](<demo%20image.png>)",
}
local linked_blocks = markdown_image.blocks(linked_text, markdown_root)
assert(#linked_blocks == 1, "local image link inside assistant text was not discovered")
assert(not linked_blocks[1]._pi_markdown_replace_line, "ordinary image link must preserve its transcript line")
assert(
  #markdown_image._parse_links("`[literal](demo%20image.png)`", markdown_root) == 0,
  "inline code was interpreted as an image link"
)
assert(
  #markdown_image._parse_links("[remote](https://example.com/demo.png)", markdown_root) == 0,
  "ordinary remote image link must not trigger a client fetch"
)
assert(image_data.prepare(linked_blocks[1], 32), "linked workspace image was not prepared")
local linked_assistant = {
  type = "assistant",
  _pi_id = "assistant:linked-image",
  message = { content = { linked_text } },
}
local linked_lines, _, _, _, linked_placements = renderer.render({ linked_assistant }, {
  width = 40,
  root = markdown_root,
  image_terminal = true,
  tools_expanded = true,
})
assert(#linked_placements == 1, "ordinary local image link did not produce a terminal placement")
assert(
  table.concat(linked_lines, "\n"):find("文件位置: content-area-image-test.png", 1, true),
  "image preview removed the original link text"
)
local linked_fallback_lines, _, _, _, linked_fallback_placements = renderer.render({ linked_assistant }, {
  width = 40,
  root = markdown_root,
  image_terminal = false,
  tools_expanded = true,
})
local linked_fallback = table.concat(linked_fallback_lines, "\n")
assert(#linked_fallback_placements == 0, "text fallback emitted a terminal placement for an image link")
assert(
  linked_fallback:find("文件位置: content-area-image-test.png", 1, true)
    and linked_fallback:find("[Image: image/png 1x1]", 1, true),
  "text fallback did not preserve both the link and image status"
)

local markdown_captured
local markdown_chat = Chat.new(markdown_root)
markdown_chat.image_backend = {
  is_terminal = function()
    return true
  end,
  sync = function(_, _, _, selected)
    markdown_captured = selected
  end,
  clear = function() end,
}
markdown_chat:open(false)
markdown_chat:end_assistant({ role = "assistant", content = { vim.deepcopy(markdown_text) }, stopReason = "stop" })
assert(markdown_captured and #markdown_captured == 1, "Chat did not prepare and place its Markdown image")
markdown_chat:close()

local linked_captured
local linked_chat = Chat.new(markdown_root)
linked_chat.image_backend = {
  is_terminal = function()
    return true
  end,
  sync = function(_, _, _, selected)
    linked_captured = selected
  end,
  clear = function() end,
}
linked_chat:open(false)
linked_chat:end_assistant({ role = "assistant", content = { vim.deepcopy(linked_text) }, stopReason = "stop" })
assert(linked_captured and #linked_captured == 1, "Chat did not place an ordinary local image link")
linked_chat:close()

if vim.fn.executable("magick") == 1 then
  local preview_chat = linked_chat
  preview_chat.image_backend = {
    is_terminal = function()
      return false
    end,
    status = function()
      return { requested = "auto", state = "unavailable", actual = "text" }
    end,
    sync = function() end,
    clear = function() end,
  }
  preview_chat:clear()
  preview_chat:open(false)
  preview_chat:end_assistant({ role = "assistant", content = { vim.deepcopy(linked_text) }, stopReason = "stop" })
  assert(
    vim.wait(5000, function()
      local rendered = table.concat(vim.api.nvim_buf_get_lines(preview_chat.buf, 0, -1, false), "\n")
      return rendered:find("▀", 1, true) ~= nil
    end, 20),
    "Chat did not replace the image link fallback with an asynchronous colored preview"
  )
  preview_chat:close()
end
assert(vim.fn.delete(markdown_root, "rf") == 0, "markdown image workspace cleanup failed")
assert(vim.uv.fs_unlink(outside_path), "outside markdown image fixture cleanup failed")

print("markdown_image_spec: ok")
