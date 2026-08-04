local config = require("pi.config")
local previous_client = package.loaded["pi.client"]
local previous_runtime = package.loaded["pi.runtime"]
local runtime

local function run()
  local root = vim.fn.getcwd()
  local defaults = config.get()
  local maximum_encoded_image = 4 * math.ceil(defaults.images.max_bytes / 3)
  assert(
    defaults.output.rpc_queue_max_bytes > maximum_encoded_image + 4096,
    "default RPC frame budget cannot carry one maximum-size image plus its JSON envelope"
  )
  local image = {
    type = "image",
    mimeType = "image/png",
    data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  }

  local rpc_capture
  local fake_client = {
    root = root,
    state = "idle",
    commands_by_name = {},
  }
  function fake_client:on_event() end
  function fake_client:start()
    return true
  end
  function fake_client:request(command, payload, callback)
    rpc_capture = { command = command, payload = payload }
    if callback then
      callback(true, {})
    end
    return "image-request"
  end

  package.loaded["pi.client"] = {
    Client = {
      new = function()
        return fake_client
      end,
    },
  }
  package.loaded["pi.runtime"] = nil
  runtime = require("pi.runtime")
  runtime.send_prompt("describe this", nil, root, nil, { image })
  assert(rpc_capture and rpc_capture.command == "prompt", "image prompt did not use the prompt RPC command")
  assert(rpc_capture.payload.message == "describe this", "image prompt text was changed")
  assert(
    rpc_capture.payload.images and rpc_capture.payload.images[1] == image,
    "image prompt was not forwarded as RPC images"
  )
  config.setup({ images = { attachment_max_count = 1 } })
  rpc_capture = nil
  runtime.send_prompt("too many", nil, root, nil, { image, image })
  assert(rpc_capture == nil, "programmatic prompt bypassed the aggregate attachment limit")
  runtime.chat_for(root):close()
end

local ok, err = xpcall(run, debug.traceback)
if runtime then
  pcall(runtime.stop, root)
end
package.loaded["pi.client"] = previous_client
package.loaded["pi.runtime"] = previous_runtime
if not ok then
  error(err)
end

print("image_rpc_spec: ok")
