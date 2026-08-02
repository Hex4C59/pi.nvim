local M = {}

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
  context = {
    max_bytes = 100000,
    include_diagnostics = true,
  },
  chat = {
    position = "right",
    width = 0.42,
    height = 0.38,
    max_input_height = 8,
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

  -- vim.tbl_deep_extend merges list indices. Lists are configuration values,
  -- so an explicitly supplied list should replace the default in full.
  if opts.extra_args then
    options.extra_args = vim.deepcopy(opts.extra_args)
  end
  if opts.root_markers then
    options.root_markers = vim.deepcopy(opts.root_markers)
  end

  return options
end

function M.get()
  return options
end

function M.command(root)
  local cmd = { options.command, "--mode", "rpc" }

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
  if security_mode == "read-only" then
    vim.list_extend(cmd, { "--tools", "read,grep,find,ls" })
  elseif security_mode == "confirm" then
    local extension = vim.fs.joinpath(plugin_root(), "extensions", "permission-gate.ts")
    vim.list_extend(cmd, { "--extension", extension })
  elseif security_mode ~= "full" then
    error("pi.nvim: security.mode must be 'read-only', 'confirm', or 'full'")
  end

  vim.list_extend(cmd, options.extra_args)
  return cmd, root
end

return M
