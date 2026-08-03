local config = require("pi.config")
local Chat = require("pi.ui.chat").Chat
local image_data = require("pi.ui.image")

local png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

local function image_block()
  return { type = "image", mimeType = "image/png", data = png_base64 }
end

local function wait_for(predicate, message, timeout)
  assert(vim.wait(timeout or 1000, predicate, 10), message)
end

local original_executable = vim.fn.executable
local original_system = vim.system
local processes = {}
local running = 0
local maximum_running = 0

vim.fn.executable = function(command)
  if command == "magick" then
    return 1
  end
  return original_executable(command)
end

local function finish_process(process, result)
  if process.done then
    return
  end
  process.done = true
  running = running - 1
  process.callback(result)
end

vim.system = function(command, _, callback)
  running = running + 1
  maximum_running = math.max(maximum_running, running)
  local process = { command = command, callback = callback, done = false }
  function process:kill(signal)
    self.kill_signal = signal
    finish_process(self, { code = 143, stderr = "terminated", stdout = "" })
    return true
  end
  function process:complete(code)
    finish_process(self, { code = code or 1, stderr = "fixture conversion failed", stdout = "" })
  end
  table.insert(processes, process)
  return process
end

config.setup({
  images = {
    backend = "auto",
    preview = { max_concurrent = 2, debounce_ms = 0, timeout_ms = 1000 },
  },
})

local concurrent_blocks = {}
for index = 1, 5 do
  local block = image_block()
  concurrent_blocks[index] = block
  assert(image_data.prepare(block, 32))
  image_data.prepare_preview(block)
end
assert(#processes == 2, "preview queue exceeded or failed to fill the configured concurrency")
local work = image_data._preview_work_counts()
assert(work.active == 2 and work.queued == 3, "preview queue accounting is incorrect")
processes[1]:complete()
wait_for(function()
  return #processes == 3
end, "preview queue did not start the next conversion after a slot was released")
assert(maximum_running == 2, "preview conversion exceeded the global concurrency limit")
for _, block in ipairs(concurrent_blocks) do
  image_data.release(block)
end
wait_for(function()
  local counts = image_data._preview_work_counts()
  return counts.active == 0 and counts.queued == 0
end, "cancelled preview queue did not settle")

config.setup({
  images = {
    backend = "auto",
    preview = { max_concurrent = 2, debounce_ms = 100, timeout_ms = 1000 },
  },
})
local resized = image_block()
local before_resize = #processes
for _, width in ipairs({ 32, 28, 24, 20 }) do
  assert(image_data.prepare(resized, width))
  image_data.prepare_preview(resized)
end
assert(#processes == before_resize, "resize debounce started an obsolete converter")
wait_for(function()
  return #processes == before_resize + 1
end, "resize debounce did not start the final converter")
local obsolete = processes[#processes]
assert(image_data.prepare(resized, 16), "resized image layout was not replaced")
assert(obsolete.kill_signal == "sigterm", "width change did not terminate the obsolete converter")
image_data.release(resized)
wait_for(function()
  return image_data._preview_work_counts().active == 0
end, "obsolete resize conversion did not settle")

config.setup({
  images = {
    backend = "auto",
    preview = { max_concurrent = 2, debounce_ms = 0, timeout_ms = 100 },
  },
})
local timed_out = image_block()
assert(image_data.prepare(timed_out, 32))
image_data.prepare_preview(timed_out)
local timeout_process = processes[#processes]
wait_for(function()
  return timeout_process.kill_signal == "sigkill"
end, "preview timeout did not terminate ImageMagick", 1000)
wait_for(function()
  return image_data.fallback(timed_out):find("timed out", 1, true) ~= nil
end, "preview timeout was not preserved as a stable fallback error")
image_data.release(timed_out)

config.setup({
  images = {
    backend = "auto",
    preview = { max_concurrent = 2, debounce_ms = 0, timeout_ms = 1000 },
  },
})
local chat = Chat.new(vim.fn.getcwd() .. "/preview-lifecycle")
local first_chat_image = image_block()
local second_chat_image = image_block()
chat.transcript.items = {
  { type = "user", content = { first_chat_image, second_chat_image } },
}
local render_callbacks = 0
chat.transcript_view._schedule_render = function()
  render_callbacks = render_callbacks + 1
end
local process_start = #processes + 1
chat.transcript_view:_prepare_images(40, 1, true)
assert(#processes == process_start + 1, "Chat did not start both owned preview conversions")
chat:destroy()
wait_for(function()
  return image_data._preview_work_counts().active == 0
end, "Chat destroy left preview conversions active")
for index = process_start, #processes do
  assert(processes[index].kill_signal == "sigterm", "Chat destroy did not terminate an owned converter")
end
assert(render_callbacks == 0, "late converter callback scheduled UI work after Chat destroy")
assert(next(chat.transcript.image_blocks) == nil, "Chat destroy retained tracked image blocks")

vim.fn.executable = original_executable
vim.system = original_system

print("image_scheduler_spec: ok")
