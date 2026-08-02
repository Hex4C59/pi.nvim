local M = {}

local function cancel(client, id)
  client:respond_ui(id, { cancelled = true })
end

local function editor(client, request)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(request.prefill or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.max(40, math.floor(vim.o.columns * 0.65))
  local height = math.max(8, math.min(#lines + 4, math.floor(vim.o.lines * 0.6)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = request.title or "Pi input",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })

  local finished = false
  local function close(response)
    if finished then
      return
    end
    finished = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    client:respond_ui(request.id, response)
  end

  local function submit()
    close({ value = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") })
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", function()
    close({ cancelled = true })
  end, { buffer = buf, silent = true })
end

function M.handle(client, request, set_editor_text)
  local method = request.method
  if method == "select" then
    vim.ui.select(request.options or {}, { prompt = request.title or "Pi" }, function(choice)
      if choice == nil then
        cancel(client, request.id)
      else
        client:respond_ui(request.id, { value = choice })
      end
    end)
  elseif method == "confirm" then
    local prompt = request.title or "Confirm"
    if request.message and request.message ~= "" then
      prompt = prompt .. ": " .. request.message
    end
    vim.ui.select({ "Allow", "Block" }, { prompt = prompt }, function(choice)
      client:respond_ui(request.id, { confirmed = choice == "Allow" })
    end)
  elseif method == "input" then
    vim.ui.input({ prompt = (request.title or "Pi") .. ": ", default = "" }, function(value)
      if value == nil then
        cancel(client, request.id)
      else
        client:respond_ui(request.id, { value = value })
      end
    end)
  elseif method == "editor" then
    editor(client, request)
  elseif method == "notify" then
    local levels = {
      info = vim.log.levels.INFO,
      warning = vim.log.levels.WARN,
      error = vim.log.levels.ERROR,
    }
    vim.notify(request.message or "", levels[request.notifyType] or vim.log.levels.INFO, { title = "Pi" })
  elseif method == "set_editor_text" and set_editor_text then
    set_editor_text(request.text or "")
  end
end

return M
