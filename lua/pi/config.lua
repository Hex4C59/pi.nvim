local M = {}

local frontend_system_prompt = table.concat({
  "The user is interacting with you through pi.nvim, a native Neovim frontend for Pi Coding Agent.",
  "Pi Coding Agent is the backend agent runtime.",
  "When UI interaction is relevant, account for the native Neovim frontend and do not assume that Pi's terminal UI or TUI-only controls are available.",
}, " ")

local defaults = {
  command = "pi",
  extra_args = {},
  root_markers = { ".git", ".pi" },
  request_timeout = 30000,
  persist_session = true,
  project_trust = "never",
  load_context_files = true,
  provider = nil,
  model = nil,
  thinking = nil,
  security = {
    mode = "confirm",
  },
  output = {
    live_max_bytes = 64 * 1024,
    live_max_lines = 2000,
    max_chunks = 256,
    tool_max_bytes = 256 * 1024,
    transcript_max_bytes = 2 * 1024 * 1024,
    rpc_queue_max_messages = 1024,
    rpc_queue_max_bytes = 16 * 1024 * 1024,
    render_interval_ms = 50,
  },
  context = {
    max_bytes = 100000,
    include_diagnostics = true,
    diagnostics_max_count = 100,
    diagnostic_max_message_bytes = 1000,
    diagnostics_max_bytes = 20 * 1024,
  },
  images = {
    max_bytes = 8 * 1024 * 1024,
    max_width = 72,
    max_height = 32,
    max_pixels = 40 * 1000 * 1000,
    cache_max_age_days = 7,
    attachment_max_count = 4,
    attachment_max_bytes = 16 * 1024 * 1024,
    backend = "auto",
    preview = {
      max_concurrent = 2,
      debounce_ms = 100,
      timeout_ms = 10000,
    },
    terminal = {
      provider = "snacks",
      auto_resize = true,
      timeout_ms = 10000,
    },
  },
  chat = {
    position = "right",
    width = 0.42,
    height = 0.38,
    max_input_height = 8,
    max_widget_height = 8,
    float = {
      width = 0.84,
      height = 0.86,
      border = "rounded",
    },
  },
}

local options = vim.deepcopy(defaults)

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.setup(opts)
  opts = opts or {}
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if opts.context and opts.context.max_chars ~= nil and opts.context.max_bytes == nil then
    options.context.max_bytes = opts.context.max_chars
  end

  local context_limits = {
    max_bytes = { minimum = 1, maximum = 64 * 1024 * 1024 },
    diagnostics_max_count = { minimum = 1, maximum = 10000 },
    diagnostic_max_message_bytes = { minimum = 1, maximum = 64 * 1024 },
    diagnostics_max_bytes = { minimum = 128, maximum = 16 * 1024 * 1024 },
  }
  for name, bounds in pairs(context_limits) do
    local value = options.context[name]
    if
      type(value) ~= "number"
      or value ~= value
      or value == math.huge
      or value == -math.huge
      or value < bounds.minimum
      or value > bounds.maximum
    then
      error(("pi.nvim: context.%s must be between %d and %d"):format(name, bounds.minimum, bounds.maximum))
    end
    options.context[name] = math.floor(value)
  end
  if type(options.context.include_diagnostics) ~= "boolean" then
    error("pi.nvim: context.include_diagnostics must be a boolean")
  end

  -- vim.tbl_deep_extend merges list indices. Lists are configuration values,
  -- so an explicitly supplied list should replace the default in full.
  if opts.extra_args then
    options.extra_args = vim.deepcopy(opts.extra_args)
  end
  if opts.root_markers then
    options.root_markers = vim.deepcopy(opts.root_markers)
  end

  local output_limits = {
    live_max_bytes = 64 * 1024 * 1024,
    live_max_lines = 1000000,
    max_chunks = 65536,
    tool_max_bytes = 64 * 1024 * 1024,
    transcript_max_bytes = 256 * 1024 * 1024,
    rpc_queue_max_messages = 65536,
    rpc_queue_max_bytes = 256 * 1024 * 1024,
    render_interval_ms = 60000,
  }
  local output_minimums = { render_interval_ms = 50 }
  for name, maximum in pairs(output_limits) do
    local value = options.output[name]
    if
      type(value) ~= "number"
      or value ~= value
      or value == math.huge
      or value == -math.huge
      or value < (output_minimums[name] or 1)
      or value > maximum
    then
      error(("pi.nvim: output.%s must be a positive integer no greater than %d"):format(name, maximum))
    end
    options.output[name] = math.floor(value)
  end

  local image_limits = {
    max_bytes = { minimum = 1024, maximum = 64 * 1024 * 1024 },
    max_width = { minimum = 12, maximum = 256 },
    max_height = { minimum = 4, maximum = 128 },
    max_pixels = { minimum = 1024, maximum = 268435456 },
    cache_max_age_days = { minimum = 1, maximum = 365 },
    attachment_max_count = { minimum = 1, maximum = 32 },
    attachment_max_bytes = { minimum = 1024, maximum = 256 * 1024 * 1024 },
  }
  for name, bounds in pairs(image_limits) do
    local value = options.images[name]
    if
      type(value) ~= "number"
      or value ~= value
      or value == math.huge
      or value == -math.huge
      or value < bounds.minimum
      or value > bounds.maximum
    then
      error(("pi.nvim: images.%s must be between %d and %d"):format(name, bounds.minimum, bounds.maximum))
    end
    options.images[name] = math.floor(value)
  end
  if not vim.tbl_contains({ "auto", "terminal", "text" }, options.images.backend) then
    error("pi.nvim: images.backend must be 'auto', 'terminal', or 'text'")
  end
  local preview = options.images.preview
  if type(preview) ~= "table" then
    error("pi.nvim: images.preview must be a table")
  end
  local preview_limits = {
    max_concurrent = { minimum = 1, maximum = 8 },
    debounce_ms = { minimum = 0, maximum = 2000 },
    timeout_ms = { minimum = 100, maximum = 60000 },
  }
  for name, bounds in pairs(preview_limits) do
    local value = preview[name]
    if
      type(value) ~= "number"
      or value ~= value
      or value == math.huge
      or value == -math.huge
      or value < bounds.minimum
      or value > bounds.maximum
    then
      error(("pi.nvim: images.preview.%s must be between %d and %d"):format(name, bounds.minimum, bounds.maximum))
    end
    preview[name] = math.floor(value)
  end
  local terminal = options.images.terminal
  if type(terminal) ~= "table" then
    error("pi.nvim: images.terminal must be a table")
  end
  if terminal.provider ~= "snacks" then
    error("pi.nvim: images.terminal.provider must be 'snacks'")
  end
  if type(terminal.auto_resize) ~= "boolean" then
    error("pi.nvim: images.terminal.auto_resize must be a boolean")
  end
  if
    type(terminal.timeout_ms) ~= "number"
    or terminal.timeout_ms ~= terminal.timeout_ms
    or terminal.timeout_ms == math.huge
    or terminal.timeout_ms == -math.huge
    or terminal.timeout_ms < 100
    or terminal.timeout_ms > 60000
  then
    error("pi.nvim: images.terminal.timeout_ms must be between 100 and 60000")
  end
  terminal.timeout_ms = math.floor(terminal.timeout_ms)

  return options
end

function M.get()
  return options
end

function M.command(root)
  local cmd = { options.command, "--mode", "rpc", "--append-system-prompt", frontend_system_prompt }

  if options.project_trust == "always" then
    table.insert(cmd, "--approve")
  elseif options.project_trust == "never" then
    table.insert(cmd, "--no-approve")
  end

  if not options.load_context_files then
    table.insert(cmd, "--no-context-files")
  end

  if not options.persist_session then
    table.insert(cmd, "--no-session")
  end

  if options.provider then
    vim.list_extend(cmd, { "--provider", options.provider })
  end
  if options.model then
    vim.list_extend(cmd, { "--model", options.model })
  end
  if options.thinking then
    vim.list_extend(cmd, { "--thinking", options.thinking })
  end

  local security_mode = options.security.mode
  local function add_extension(name)
    vim.list_extend(cmd, { "--extension", vim.fs.joinpath(plugin_root(), "extensions", name) })
  end
  if security_mode == "read-only" then
    vim.list_extend(cmd, { "--tools", "read,grep,find,ls,todo" })
    add_extension("workspace-guard.ts")
  elseif security_mode == "confirm" then
    add_extension("permission-gate.ts")
  elseif security_mode ~= "full" then
    error("pi.nvim: security.mode must be 'read-only', 'confirm', or 'full'")
  end
  add_extension("session-root-guard.ts")
  add_extension("todo.ts")

  vim.list_extend(cmd, options.extra_args)
  return cmd, root
end

return M
