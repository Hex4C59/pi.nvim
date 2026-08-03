local SnacksBackend = require("pi.ui.image.backends.snacks")

local created = {}
local closed = 0
local foreign_closed = 0
local fake_snacks = {
  config = { image = { enabled = true } },
  image = {
    terminal = {
      detect = function(callback)
        callback({ supported = true })
      end,
    },
    supports_terminal = function()
      return true
    end,
    placement = {
      new = function(buf, path, opts)
        local handle = {
          close = function()
            closed = closed + 1
          end,
        }
        table.insert(created, { buf = buf, path = path, opts = opts, handle = handle })
        return handle
      end,
    },
  },
}
local adapter = SnacksBackend.new({ snacks = fake_snacks, timeout_ms = 1000 })
local available
adapter:probe(function(value)
  available = value
end)
assert(available == true, "Snacks adapter did not report supported terminal")

local placement_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(placement_buf, 0, -1, false, { "      ", "      ", "      " })
local descriptor = {
  key = "instance:1:digest:2x2",
  path = "/tmp/pi-nvim-image-fixture.png",
  row = 0,
  col = 3,
  width = 2,
  height = 2,
  range_height = 1,
  conceal = true,
  block = {},
}
adapter:sync(placement_buf, nil, { descriptor }, error)
assert(#created == 1, "initial terminal placement was not created")
assert(created[1].opts.pos[1] == 1 and created[1].opts.pos[2] == 3, "Snacks position uses wrong indexing")
assert(created[1].opts.range[3] == 1, "Snacks range duplicated the terminal image's visual rows")
assert(created[1].opts.conceal == true, "Snacks did not overlay the image on its anchor")
adapter:sync(placement_buf, nil, { vim.deepcopy(descriptor) }, error)
assert(#created == 1, "unchanged placement was uploaded again")

local moved = vim.deepcopy(descriptor)
moved.row = 1
adapter:sync(placement_buf, nil, { moved }, error)
assert(#created == 2 and closed == 1, "moved placement was not replaced incrementally")
adapter:sync(placement_buf, nil, {}, error)
assert(closed == 2, "removed placement handle was not closed")
local foreign = {
  close = function()
    foreign_closed = foreign_closed + 1
  end,
}
adapter:clear(placement_buf)
assert(foreign and foreign_closed == 0, "adapter touched a placement it does not own")

local unsupported
SnacksBackend.new({
  snacks = {
    config = { image = { enabled = true } },
    image = {
      terminal = {
        detect = function(callback)
          callback({ supported = false })
        end,
      },
      supports_terminal = function()
        return false
      end,
      placement = {
        new = function()
          error("must not create")
        end,
      },
    },
  },
}):probe(function(value, reason)
  unsupported = value == false and reason:find("does not support", 1, true) ~= nil
end)
assert(unsupported, "unsupported terminal was not explained")

local creation_failure
local failing_adapter = SnacksBackend.new({
  snacks = {
    config = { image = { enabled = true } },
    image = {
      placement = {
        new = function()
          error("fixture create failure")
        end,
      },
    },
  },
})
assert(
  failing_adapter:sync(placement_buf, nil, { descriptor }, function(_, reason)
    creation_failure = reason
  end),
  "one failed image must not disable the whole adapter"
)
assert(creation_failure:find("fixture create failure", 1, true), "placement creation failure was not isolated")

local timeout_failure
local timeout_closed = 0
local timeout_aborted = 0
local timeout_adapter = SnacksBackend.new({
  timeout_ms = 100,
  snacks = {
    config = { image = { enabled = true } },
    image = {
      placement = {
        new = function()
          return {
            ready = function()
              return false
            end,
            img = {
              failed = function()
                return false
              end,
              _convert = {
                abort = function()
                  timeout_aborted = timeout_aborted + 1
                end,
              },
            },
            close = function()
              timeout_closed = timeout_closed + 1
            end,
          }
        end,
      },
    },
  },
})
timeout_adapter:sync(placement_buf, nil, { descriptor }, function(_, reason)
  timeout_failure = reason
end)
assert(
  vim.wait(500, function()
    return timeout_failure ~= nil
  end, 10),
  "image conversion timeout did not fire"
)
assert(timeout_failure:find("timed out", 1, true), "image conversion timeout reason was lost")
assert(timeout_closed == 1, "timed-out placement was not closed")
assert(timeout_aborted == 1, "timed-out provider conversion was not aborted")

local throwing_close_adapter = SnacksBackend.new({
  snacks = {
    config = { image = { enabled = true } },
    image = {
      placement = {
        new = function()
          return {
            close = function()
              error("fixture close failure")
            end,
          }
        end,
      },
    },
  },
})
throwing_close_adapter:sync(placement_buf, nil, { descriptor }, error)
assert(
  pcall(throwing_close_adapter.clear, throwing_close_adapter, placement_buf),
  "handle close failure escaped cleanup"
)

vim.api.nvim_buf_delete(placement_buf, { force = true })

print("snacks_image_backend_spec: ok")
