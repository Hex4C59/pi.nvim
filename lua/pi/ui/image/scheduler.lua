local config = require("pi.config")

local M = {}
local Scheduler = {}
Scheduler.__index = Scheduler

local function default_config()
  local images = config.get().images or {}
  return images.preview or { max_concurrent = 2, debounce_ms = 100, timeout_ms = 10000 }
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Scheduler.new(opts)
  opts = opts or {}
  return setmetatable({
    config = opts.config or default_config,
    system = opts.system,
    queue = {},
    first = 1,
    last = 0,
    active = 0,
  }, Scheduler)
end

function Scheduler:_finish(task, result)
  if task.finished then
    return
  end
  task.finished = true
  close_timer(task.timeout_timer)
  task.timeout_timer = nil
  task.process = nil
  if task.phase == "running" then
    self.active = math.max(0, self.active - 1)
  end

  local callback = task.callback
  task.callback = nil
  task.prepared = nil
  if not task.cancelled and callback then
    result = result or { code = -1, stderr = "preview converter returned no result", stdout = "" }
    result.timed_out = task.timed_out == true
    vim.schedule(function()
      pcall(callback, result, task)
    end)
  end
  self:_pump()
end

function Scheduler:_start(task)
  if task.cancelled or task.finished then
    return
  end
  task.phase = "running"
  self.active = self.active + 1
  local prepared = task.prepared
  local command = {
    "magick",
    prepared.path,
    "-auto-orient",
    "-alpha",
    "on",
    "-resize",
    ("%dx%d!"):format(prepared.width, prepared.height * 2),
    "-depth",
    "8",
    "rgba:-",
  }
  local system = self.system or vim.system
  local ok, process = pcall(system, command, { text = false }, function(result)
    vim.schedule(function()
      self:_finish(task, result)
    end)
  end)
  if not ok then
    self:_finish(task, { code = -1, stderr = tostring(process), stdout = "" })
    return
  end
  task.process = process
  local timeout = vim.uv.new_timer()
  task.timeout_timer = timeout
  timeout:start(
    task.timeout_ms,
    0,
    vim.schedule_wrap(function()
      if task.finished or task.cancelled or task.phase ~= "running" then
        return
      end
      close_timer(task.timeout_timer)
      task.timeout_timer = nil
      task.timed_out = true
      if task.process then
        pcall(task.process.kill, task.process, "sigkill")
      end
    end)
  )
end

function Scheduler:_pump()
  local maximum = math.max(1, math.floor(tonumber(self.config().max_concurrent) or 2))
  while self.active < maximum and self.first <= self.last do
    local task = self.queue[self.first]
    self.queue[self.first] = nil
    self.first = self.first + 1
    if task and not task.cancelled and not task.finished then
      self:_start(task)
    end
  end
  if self.first > self.last then
    self.first = 1
    self.last = 0
  end
end

function Scheduler:_enqueue(task)
  if task.cancelled or task.finished then
    return
  end
  task.phase = "queued"
  self.last = self.last + 1
  self.queue[self.last] = task
  self:_pump()
end

function Scheduler:schedule(prepared, callback)
  local options = self.config()
  local task = {
    prepared = prepared,
    callback = callback,
    timeout_ms = math.max(1, math.floor(tonumber(options.timeout_ms) or 10000)),
  }
  local delay = math.max(0, math.floor(tonumber(options.debounce_ms) or 100))
  if delay == 0 then
    self:_enqueue(task)
    return task
  end
  task.phase = "debouncing"
  local timer = vim.uv.new_timer()
  task.debounce_timer = timer
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      close_timer(task.debounce_timer)
      task.debounce_timer = nil
      self:_enqueue(task)
    end)
  )
  return task
end

function Scheduler:cancel(task)
  if not task or task.finished or task.cancelled then
    return false
  end
  task.cancelled = true
  close_timer(task.debounce_timer)
  close_timer(task.timeout_timer)
  task.debounce_timer = nil
  task.timeout_timer = nil
  task.callback = nil
  task.prepared = nil
  if task.phase == "running" and task.process then
    pcall(task.process.kill, task.process, "sigterm")
  else
    task.finished = true
    self:_pump()
  end
  return true
end

function Scheduler:work_counts()
  local queued = 0
  for index = self.first, self.last do
    local task = self.queue[index]
    if task and not task.cancelled and not task.finished then
      queued = queued + 1
    end
  end
  return { active = self.active, queued = queued }
end

local default_scheduler = Scheduler.new()

function M.schedule(prepared, callback)
  return default_scheduler:schedule(prepared, callback)
end

function M.cancel(task)
  return default_scheduler:cancel(task)
end

function M.work_counts()
  return default_scheduler:work_counts()
end

M.Scheduler = Scheduler
return M
