local image_data = require("pi.ui.image")
local namespace = vim.api.nvim_create_namespace("pi.nvim")

local ImagePreview = {}
ImagePreview.__index = ImagePreview

function ImagePreview.new(deps)
  return setmetatable({
    root = deps.root,
    backend = deps.backend,
    ui_group = deps.ui_group,
    border = deps.border,
    track_image = deps.track_image,
    release_image = deps.release_image,
    buf = nil,
    win = nil,
    block = nil,
  }, ImagePreview)
end

local function style_window(win, normal_group)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].list = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].winhighlight = ("Normal:%s,NormalNC:%s,EndOfBuffer:%s,WinSeparator:PiPanelBorder,FloatBorder:PiPanelBorder"):format(
    normal_group,
    normal_group,
    normal_group
  )
end

function ImagePreview:close()
  local buf = self.buf
  local win = self.win
  local block = self.block
  self.buf = nil
  self.win = nil
  self.block = nil
  if block then
    self.release_image(block)
  end
  if self.backend and buf then
    self.backend:clear(buf)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

function ImagePreview:_render_blocks(block)
  local buf = self.buf
  if self.block ~= block or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local preview = image_data.preview(block)
  local lines = {}
  if preview then
    for _, preview_row in ipairs(preview.rows) do
      table.insert(lines, preview_row.text)
    end
  else
    lines = { image_data.fallback(block) }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if preview then
    for row, preview_row in ipairs(preview.rows) do
      for _, mark in ipairs(preview_row.marks) do
        vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, mark.start_col, {
          end_col = mark.end_col,
          hl_group = mark.highlight,
          priority = 150,
        })
      end
    end
  end
  vim.bo[buf].modifiable = false
end

function ImagePreview:open(descriptor)
  local prepared = descriptor and image_data.prepared(descriptor.block)
  if not prepared then
    return false
  end
  self:close()

  local maximum_width = math.max(12, vim.o.columns - 4)
  local maximum_height = math.max(4, vim.o.lines - vim.o.cmdheight - 4)
  local block = {
    type = "image",
    mimeType = prepared.mime_type,
    path = prepared.path,
  }
  self.track_image(block)
  local zoom = image_data.prepare(block, maximum_width, nil, {
    max_width = maximum_width,
    max_height = maximum_height,
  })
  if not zoom then
    self.release_image(block)
    return false
  end

  local width = math.max(12, zoom.width)
  local height = math.max(4, zoom.height)
  local buf = vim.api.nvim_create_buf(false, true)
  local label = ("Pi Image Preview · %s"):format(vim.fs.basename(self.root))
  if not pcall(vim.api.nvim_buf_set_name, buf, label) then
    pcall(vim.api.nvim_buf_set_name, buf, label .. " · " .. vim.fn.sha256(self.root):sub(1, 6))
  end
  vim.b[buf].pi_kind = "image_preview"
  vim.b[buf].pi_root = self.root
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pi_image_preview"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = self.border(),
    title = { { (" Image %dx%d "):format(prepared.pixel_width, prepared.pixel_height), "PiPanelTitle" } },
    title_pos = "center",
    zindex = 80,
  })
  style_window(win, "PiCanvasNormal")
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  self.buf = buf
  self.win = win
  self.block = block

  local function close()
    self:close()
  end
  for _, key in ipairs({ "q", "<Esc>", "<CR>", "<LeftMouse>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, silent = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.ui_group,
    pattern = tostring(win),
    once = true,
    callback = function()
      if self.win == win then
        self:close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = self.ui_group,
    buffer = buf,
    once = true,
    callback = function(event)
      if self.buf ~= event.buf then
        return
      end
      local preview_win = self.win
      local preview_block = self.block
      self.buf = nil
      self.win = nil
      self.block = nil
      if preview_block then
        self.release_image(preview_block)
      end
      if self.backend then
        self.backend:clear(event.buf)
      end
      if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        pcall(vim.api.nvim_win_close, preview_win, true)
      end
    end,
  })

  if self.backend and self.backend:is_terminal() then
    self.backend:sync(buf, win, {
      {
        key = "preview:" .. zoom.key,
        content_key = zoom.key,
        block = block,
        path = zoom.path,
        row = 0,
        col = 0,
        width = zoom.width,
        height = zoom.height,
        range_height = 1,
        conceal = true,
        inline = false,
      },
    })
  else
    image_data.prepare_preview(block, function()
      self:_render_blocks(block)
    end)
    self:_render_blocks(block)
  end
  return true
end

function ImagePreview:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function ImagePreview:set_backend(backend)
  self.backend = backend
end

function ImagePreview:owns_buffer(bufnr)
  return bufnr ~= nil and self.buf == bufnr
end

function ImagePreview:destroy()
  self:close()
end

return { ImagePreview = ImagePreview }
