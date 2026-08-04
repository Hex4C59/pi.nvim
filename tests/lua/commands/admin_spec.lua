local root = vim.fn.getcwd()
local notifications = {}
local errors = {}
local refreshes = 0
local projection_replacements = 0
local chat_generation = 0

local client = {
  root = root,
  session = { rpcCapabilities = { "administrative_workflows" } },
  requests = {},
}

function client:request(command, payload, callback, timeout)
  local entry = { command = command, payload = vim.deepcopy(payload), callback = callback, timeout = timeout }
  table.insert(self.requests, entry)
  return "request-" .. #self.requests
end

local function latest(command)
  for index = #client.requests, 1, -1 do
    if client.requests[index].command == command then
      return client.requests[index]
    end
  end
  error("missing request: " .. command)
end

local function respond(command, data)
  local entry = latest(command)
  assert(not entry.responded, "request responded twice: " .. command)
  entry.responded = true
  entry.callback(true, data or {})
  return entry
end

local fake_runtime = {
  rpc_unavailable_commands = {
    login = "installed Pi does not advertise administrative workflows",
  },
  get_client = function()
    return client
  end,
  client_is_current = function(candidate)
    return candidate == client
  end,
  chat_action_generation = function()
    return chat_generation
  end,
  has_capability = function(candidate, capability)
    return candidate == client
      and capability == "administrative_workflows"
      and vim.tbl_contains(candidate.session.rpcCapabilities or {}, capability)
  end,
  notify_error = function(message)
    table.insert(errors, message)
  end,
  refresh_administrative_state = function(candidate)
    assert(candidate == client)
    refreshes = refreshes + 1
  end,
  replace_extension_projection = function(candidate)
    assert(candidate == client)
    projection_replacements = projection_replacements + 1
  end,
  chat_for = function()
    return {
      update_state = function() end,
    }
  end,
}

local function surface()
  return {
    closed = false,
    close = function(self)
      self.closed = true
    end,
  }
end

local fake_ui = {}
function fake_ui.select(options)
  fake_ui.last_select = options
  return surface()
end
function fake_ui.confirm(options)
  fake_ui.last_confirm = options
  return surface()
end
function fake_ui.input(options)
  fake_ui.last_input = options
  fake_ui.last_input_surface = surface()
  return fake_ui.last_input_surface
end
function fake_ui.multi_select(options)
  fake_ui.last_multi = options
  return surface()
end
fake_runtime.open_admin_select = fake_ui.select
fake_runtime.open_admin_confirm = fake_ui.confirm
fake_runtime.open_admin_input = fake_ui.input
fake_runtime.open_admin_multi_select = fake_ui.multi_select

local previous_runtime = package.loaded["pi.runtime"]
local previous_admin = package.loaded["pi.commands.admin"]
local original_notify = vim.notify

local function run()
  package.loaded["pi.runtime"] = fake_runtime
  package.loaded["pi.commands.admin"] = nil
  local admin = require("pi.commands.admin")
  vim.notify = function(message, level, options)
    table.insert(notifications, { message = message, level = level, title = options and options.title })
  end

  admin.login(root, "")
  respond("get_auth_providers", {
    providers = {
      {
        id = "other",
        name = "Other",
        methods = { { type = "api_key", name = "API key", interactive = true } },
      },
      {
        id = "fixture",
        name = "Fixture",
        methods = {
          { type = "api_key", name = "API key", interactive = true },
          { type = "oauth", name = "OAuth", interactive = true },
        },
      },
    },
  })
  assert(fake_ui.last_select.title == "Pi login provider", "login skipped the native provider selector")
  fake_ui.last_select.on_select(fake_ui.last_select.items[2])
  assert(fake_ui.last_select.title == "Pi authentication method", "login skipped the native method selector")
  fake_ui.last_select.on_select(fake_ui.last_select.items[2])
  local begin = latest("begin_auth")
  assert(begin.payload.provider == "fixture" and begin.payload.method == "oauth", "login lost provider metadata")
  respond("begin_auth", { flowId = "flow-1" })

  admin.handle_event(client, {
    type = "auth_notice",
    flowId = "flow-1",
    noticeType = "auth_url",
    instructions = "Open the provider page",
    url = "https://auth.invalid/fixture",
  })
  admin.handle_event(client, {
    type = "auth_notice",
    flowId = "flow-1",
    noticeType = "device_code",
    verificationUri = "https://device.invalid",
    userCode = "ABCD-1234",
  })
  assert(
    notifications[#notifications].message:find("ABCD-1234", 1, true),
    "device-code authentication instructions were not reported"
  )

  admin.handle_event(client, {
    type = "auth_prompt",
    flowId = "flow-1",
    promptId = "prompt-1",
    promptType = "secret",
    message = "Provider secret",
    placeholder = "secret",
    sensitive = true,
  })
  assert(fake_ui.last_input.sensitive == true, "authoritative secret metadata did not reach the UI")
  local secret = "fixture-private-secret"
  fake_ui.last_input.on_submit(secret)
  local submitted = latest("submit_auth_value")
  assert(
    submitted.payload.flowId == "flow-1"
      and submitted.payload.promptId == "prompt-1"
      and submitted.payload.value == secret,
    "authentication response lost flow correlation"
  )
  submitted.payload.value = nil
  respond("submit_auth_value")
  admin.handle_event(client, {
    type = "auth_prompt",
    flowId = "flow-1",
    promptId = "prompt-2",
    promptType = "text",
    message = "Verification",
    sensitive = false,
  })
  local current_prompt_surface = fake_ui.last_input_surface
  admin.handle_event(client, {
    type = "auth_prompt_cancel",
    flowId = "flow-1",
    promptId = "prompt-1",
    reason = "signal",
  })
  assert(not current_prompt_surface.closed, "stale prompt cancellation closed a newer authentication prompt")
  fake_ui.last_input.on_submit("verified")
  local verification = latest("submit_auth_value")
  assert(verification.payload.promptId == "prompt-2", "second authentication prompt lost correlation")
  verification.payload.value = nil
  respond("submit_auth_value")
  admin.handle_event(client, {
    type = "auth_complete",
    flowId = "flow-1",
    provider = "fixture",
    method = "oauth",
    success = true,
  })
  assert(refreshes == 1, "successful authentication did not refresh state, models, and commands")
  for _, notification in ipairs(notifications) do
    assert(not notification.message:find(secret, 1, true), "authentication secret leaked into a notification")
  end
  secret = nil

  admin.logout(root, "fixture")
  respond("get_auth_providers", {
    providers = {
      { id = "fixture", name = "Fixture", storedCredential = "oauth", methods = {} },
    },
  })
  assert(fake_ui.last_confirm.title == "Remove provider credential", "logout skipped confirmation")
  fake_ui.last_confirm.on_confirm(true)
  assert(latest("logout_provider").payload.provider == "fixture", "logout targeted the wrong provider")
  respond("logout_provider")
  assert(refreshes == 2, "logout did not refresh authentication state")

  admin.trust(root)
  respond("get_project_trust", {
    cwd = root,
    active = false,
    saved = nil,
    restartRequired = false,
  })
  assert(fake_ui.last_select.title:find("Pi project trust", 1, true), "trust skipped the native selector")
  fake_ui.last_select.on_select(fake_ui.last_select.items[2])
  assert(latest("set_project_trust").payload.decision == "untrusted", "trust sent the wrong decision")
  respond("set_project_trust", {
    cwd = root,
    active = false,
    saved = { path = root, decision = "untrusted" },
    restartRequired = true,
  })
  assert(
    notifications[#notifications].message:find("Permission mode is unchanged", 1, true),
    "trust presentation conflated project trust with tool permissions"
  )

  admin.reload(root)
  assert(latest("reload_resources").timeout == 0, "resource reload retained a client timeout")
  respond("reload_resources", {
    resources = { extensions = 3, skills = 2, prompts = 1, themes = 1 },
  })
  assert(projection_replacements == 1, "reload did not replace stale Extension projection state")

  admin.scoped_models(root)
  respond("get_model_scope", {
    available = {
      { provider = "fixture", id = "one" },
      { provider = "fixture", id = "two" },
    },
    enabled = { { provider = "fixture", id = "one" } },
    allEnabled = false,
  })
  assert(fake_ui.last_multi.title == "Pi model cycling scope", "model scope skipped the native multi-selector")
  fake_ui.last_multi.on_select({ fake_ui.last_multi.items[2] })
  local set_scope = latest("set_model_scope")
  assert(
    set_scope.payload.persist == true and #set_scope.payload.models == 1 and set_scope.payload.models[1].id == "two",
    "model scope lost its structured persistent selection"
  )
  respond("set_model_scope", {
    available = fake_ui.last_multi.items,
    enabled = { fake_ui.last_multi.items[2] },
    allEnabled = false,
  })
  assert(refreshes == 3, "model scope did not refresh Pi state")

  local previous_select_options = fake_ui.last_select
  admin.login(root, "")
  chat_generation = chat_generation + 1
  respond("get_auth_providers", {
    providers = {
      { id = "stale-one", name = "Stale one", methods = { { type = "oauth", interactive = true } } },
      { id = "stale-two", name = "Stale two", methods = { { type = "oauth", interactive = true } } },
    },
  })
  assert(fake_ui.last_select == previous_select_options, "a response after Chat close reopened an admin menu")

  client.session.rpcCapabilities = {}
  local request_count = #client.requests
  admin.login(root, "fixture")
  assert(#client.requests == request_count, "unsupported Pi received an administrative RPC command")
  assert(
    notifications[#notifications].level == vim.log.levels.WARN
      and notifications[#notifications].message:find("does not advertise", 1, true),
    "unsupported Pi did not receive the capability-gated fallback"
  )
  assert(#errors == 0, table.concat(errors, "\n"))
end

local ok, err = xpcall(run, debug.traceback)
vim.notify = original_notify
package.loaded["pi.runtime"] = previous_runtime
package.loaded["pi.commands.admin"] = previous_admin
if not ok then
  error(err)
end

print("admin_spec: ok")
