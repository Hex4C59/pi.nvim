local config = require("pi.config")

local M = {}

local supported_mime_types = {
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
  "image/bmp",
}

local mime_extensions = {
  ["image/png"] = ".png",
  ["image/jpeg"] = ".jpg",
  ["image/webp"] = ".webp",
  ["image/gif"] = ".gif",
  ["image/bmp"] = ".bmp",
}

local function base_mime_type(value)
  return (value or ""):match("^[^;]+") or value or ""
end

local function run(command, args, timeout)
  if vim.fn.executable(command) ~= 1 then
    return nil
  end
  local ok, process = pcall(vim.system, vim.list_extend({ command }, args or {}), { text = false })
  if not ok or not process then
    return nil
  end
  local result = process:wait(timeout or 1000)
  if not result or result.code ~= 0 then
    return nil
  end
  return result.stdout or ""
end

local function is_wayland()
  return vim.env.WAYLAND_DISPLAY ~= nil or vim.env.XDG_SESSION_TYPE == "wayland"
end

local function select_mime_type(types)
  local normalized = {}
  for value in (types or ""):gmatch("[^\r\n]+") do
    local mime = base_mime_type(vim.trim(value))
    if mime ~= "" then
      normalized[mime] = true
    end
  end
  for _, mime in ipairs(supported_mime_types) do
    if normalized[mime] then
      return mime
    end
  end
  return nil
end

local function read_wayland()
  local types = run("wl-paste", { "--list-types" }, 500)
  local mime = select_mime_type(types)
  if not mime then
    return nil
  end
  local data = run("wl-paste", { "--type", mime, "--no-newline" }, 3000)
  if not data or #data == 0 then
    return nil
  end
  return data, mime
end

local function read_x11()
  local targets = run("xclip", { "-selection", "clipboard", "-t", "TARGETS", "-o" }, 500)
  local mime = select_mime_type(targets)
  local candidates = mime and { mime } or {}
  for _, supported in ipairs(supported_mime_types) do
    if supported ~= mime then
      table.insert(candidates, supported)
    end
  end
  for _, candidate in ipairs(candidates) do
    local data = run("xclip", { "-selection", "clipboard", "-t", candidate, "-o" }, 3000)
    if data and #data > 0 then
      return data, candidate
    end
  end
  return nil
end

local function image_content(data, mime)
  local maximum = (config.get().images or {}).max_bytes or 8 * 1024 * 1024
  if #data > maximum then
    return nil, ("Clipboard image is too large (%s; limit %s)"):format(#data, maximum)
  end
  mime = base_mime_type(mime)
  if not mime_extensions[mime] then
    return nil, "Clipboard image format is not supported"
  end
  return {
    type = "image",
    mimeType = mime,
    data = vim.base64.encode(data),
  }
end

function M.read_image()
  local data, mime
  if is_wayland() then
    data, mime = read_wayland()
  end
  if not data then
    data, mime = read_x11()
  end
  if not data then
    return nil
  end
  return image_content(data, mime)
end

function M.read_text()
  local ok, text = pcall(vim.fn.getreg, "+")
  if ok and type(text) == "string" and text ~= "" then
    return text
  end
  return nil
end

return M
