local config = require("pi.config")
local image_data = require("pi.ui.image")
local renderer = require("pi.ui.render")
local TranscriptView = require("pi.ui.transcript.view").TranscriptView

config.setup({
  security = { mode = "confirm" },
  images = { backend = "text", max_width = 32, max_height = 16 },
})

local fixture_index = 0

local function new_fixture(overrides)
  overrides = overrides or {}
  fixture_index = fixture_index + 1
  local items = overrides.items or {}
  local state = vim.tbl_extend("force", {
    hide_thinking = false,
    tools_expanded = false,
    process_expanded = true,
    model = "fixture-model",
    thinking = "medium",
    permission_mode = "confirm",
    overlay_height = 0,
  }, overrides.state or {})
  local group = vim.api.nvim_create_augroup("pi_transcript_view_spec_" .. fixture_index, { clear = true })
  local win
  local backend = overrides.backend
  if backend == nil then
    backend = {
      terminal = overrides.terminal == true,
      sync_calls = {},
      clear_calls = 0,
      is_terminal = function(self)
        return self.terminal
      end,
      status = function()
        return { requested = "text", state = "ready" }
      end,
      sync = function(self, buf, current_win, placements)
        table.insert(self.sync_calls, { buf = buf, win = current_win, placements = vim.list_slice(placements) })
      end,
      clear = function(self)
        self.clear_calls = self.clear_calls + 1
      end,
    }
  elseif backend == false then
    backend = nil
  end
  local observed = {
    materialize = 0,
    tracked = {},
    refreshed = {},
    actions = {},
  }
  local actions = {}
  for _, name in ipairs({
    "close",
    "focus_input",
    "abort",
    "select_model",
    "cycle_model",
    "cycle_thinking_level",
    "toggle_tools",
    "toggle_thinking",
    "copy_last_assistant",
    "left_mouse",
    "open_image_preview",
  }) do
    actions[name] = function(...)
      table.insert(observed.actions, { name = name, args = { ... } })
    end
  end
  local view = TranscriptView.new({
    root = overrides.root or (vim.fn.getcwd() .. "/transcript-view-fixture-" .. fixture_index),
    output = vim.tbl_extend("force", {
      transcript_max_bytes = 1024 * 1024,
      render_interval_ms = 50,
    }, overrides.output or {}),
    image_backend = backend,
    ui_group = group,
    window = function()
      return win
    end,
    items = function()
      return items
    end,
    state = function()
      return state
    end,
    widget_content = overrides.widget_content or function()
      return {}, {}
    end,
    permission_content = overrides.permission_content or function()
      return {}, {}
    end,
    body_bytes = overrides.body_bytes or function()
      return 0
    end,
    materialize = function()
      observed.materialize = observed.materialize + 1
    end,
    process_active = overrides.process_active or function()
      return false
    end,
    track_image = function(block)
      table.insert(observed.tracked, block)
      return block
    end,
    refresh_image_accounting = function(item, block)
      table.insert(observed.refreshed, { item = item, block = block })
      return true
    end,
    actions = actions,
  })

  local fixture = {
    view = view,
    items = items,
    state = state,
    backend = backend,
    observed = observed,
    group = group,
  }
  function fixture:open(width, height)
    local buf = assert(view:ensure_buffer(), "TranscriptView did not create a buffer")
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = width or 60,
      height = height or 12,
      style = "minimal",
    })
    self.win = win
    return buf, win
  end
  function fixture:cleanup()
    pcall(function()
      view:destroy()
    end)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  return fixture
end

local function with_view(overrides, callback)
  local fixture = new_fixture(overrides)
  local ok, err = xpcall(function()
    callback(fixture)
  end, debug.traceback)
  fixture:cleanup()
  assert(ok, err)
end

local function buffer_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

with_view({}, function(fixture)
  local view = fixture.view
  assert(not view:has_buffer() and not view:owns_buffer(1), "TranscriptView created its buffer eagerly")
  local buf = view:ensure_buffer()
  assert(view:has_buffer() and view:owns_buffer(buf), "TranscriptView did not claim its own buffer")
  assert(vim.api.nvim_buf_get_name(buf):find("Pi Chat", 1, true), "transcript buffer name is missing")
  assert(vim.b[buf].pi_kind == "chat" and vim.b[buf].pi_root == view.root, "buffer metadata is incomplete")
  assert(
    vim.bo[buf].buftype == "nofile" and vim.bo[buf].bufhidden == "hide",
    "TranscriptView buffer did not retain nofile/hidden lifecycle options"
  )
  assert(
    vim.bo[buf].swapfile == false and vim.bo[buf].filetype == "markdown",
    "TranscriptView buffer enabled swap or lost its Markdown filetype"
  )
  assert(vim.bo[buf].modifiable == false, "transcript buffer remained modifiable")
  local mappings = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    mappings[mapping.lhs] = true
  end
  assert(mappings.q and mappings.i and mappings.a and mappings["<CR>"], "transcript keymaps are incomplete")
  assert(view:ensure_buffer() == buf, "ensure_buffer replaced a valid owned buffer")
  view:destroy()
  view:destroy()
  assert(not view:has_buffer() and not view:owns_buffer(buf), "destroy retained transcript buffer ownership")
  assert(not vim.api.nvim_buf_is_valid(buf), "destroy left the transcript buffer alive")
end)

with_view({
  items = {
    { type = "user", _pi_id = "user:1", text = "question", content = {} },
    {
      type = "tool",
      _pi_id = "tool:1",
      id = "tool-1",
      name = "read",
      state = "done",
      args = { path = "README.md" },
      result = { content = { { type = "text", text = "contents" } } },
    },
  },
  state = { overlay_height = 2, process_expanded = true, tools_expanded = true },
}, function(fixture)
  local authoritative = vim.deepcopy(fixture.items)
  local buf, win = fixture:open(60, 12)
  fixture.view:render()
  local expected = renderer.render(fixture.items, {
    hide_thinking = false,
    tools_expanded = true,
    collapse_processes = true,
    process_expanded = true,
    process_active = false,
    image_terminal = false,
    root = fixture.view.root,
    width = vim.api.nvim_win_get_width(win),
    welcome = {
      model = "fixture-model",
      thinking = "medium",
      root = fixture.view.root,
      permission = "confirm",
      security = "confirm",
    },
  })
  vim.list_extend(expected, { "", "" })
  assert(vim.deep_equal(buffer_lines(buf), expected), "full TranscriptView projection diverged from renderer output")
  assert(vim.deep_equal(fixture.items, authoritative), "full render mutated structured source items")
  assert(vim.bo[buf].modifiable == false, "controlled render left the buffer modifiable")
  assert(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) > 0, "semantic renderer marks were not applied")
  assert(#fixture.view.tool_ranges == 1, "expanded process did not retain its tool range")
  assert(fixture.view:projection_bytes() > 0, "projection memory was not accounted")
  local line_bytes = 0
  for _, line in ipairs(buffer_lines(buf)) do
    line_bytes = line_bytes + #line
  end
  assert(fixture.view:projection_bytes() >= line_bytes, "projection accounting omitted rendered lines")
  assert(fixture.backend.sync_calls[#fixture.backend.sync_calls].win == win, "backend sync received the wrong window")

  fixture.state.process_expanded = false
  fixture.view:invalidate()
  fixture.view:render()
  assert(#fixture.view.process_ranges == 1 and #fixture.view.tool_ranges == 0, "collapsed process ranges are incorrect")
end)

with_view({
  items = {
    { type = "user", _pi_id = "u1", text = "first", content = {} },
    { type = "assistant", _pi_id = "a1", message = { content = { { type = "text", text = "answer one" } } } },
    { type = "user", _pi_id = "u2", text = "second", content = {} },
    { type = "assistant", _pi_id = "a2", message = { content = { { type = "text", text = "partial" } } } },
  },
  process_active = function()
    return true
  end,
}, function(fixture)
  local view = fixture.view
  local buf = fixture:open(60, 12)
  view:render()
  local prefix_rows = view.render_cache.result.lines and #view.render_cache.result.lines or 0
  local prefix_marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 0, 0 }, { math.max(0, prefix_rows - 1), -1 }, {})
  assert(#prefix_marks > 0, "incremental fixture has no stable prefix Extmark")

  fixture.items[4].message = { content = { { type = "text", text = "partial with another streamed chunk" } } }
  local original_render = renderer.render
  local original_set_lines = vim.api.nvim_buf_set_lines
  local rendered_counts = {}
  local writes = {}
  renderer.render = function(items, opts)
    table.insert(rendered_counts, #items)
    return original_render(items, opts)
  end
  vim.api.nvim_buf_set_lines = function(target, first, last, strict, lines)
    if target == buf then
      table.insert(writes, { first = first, last = last, count = #lines })
    end
    return original_set_lines(target, first, last, strict, lines)
  end
  local ok, err = pcall(function()
    view:render()
  end)
  renderer.render = original_render
  vim.api.nvim_buf_set_lines = original_set_lines
  assert(ok, err)
  assert(vim.deep_equal(rendered_counts, { 2 }), "stable prefix was rendered again during streaming")
  assert(#writes == 1 and writes[1].first > 0 and writes[1].last ~= -1, "streaming did not use one partial write")
  assert(#view.render_frame.dynamic_lines < vim.api.nvim_buf_line_count(buf), "dynamic frame duplicated the transcript")
  local updated_marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 0, 0 }, { math.max(0, prefix_rows - 1), -1 }, {})
  assert(prefix_marks[1][1] == updated_marks[1][1], "stable prefix Extmark identity changed")

  view:invalidate_item(fixture.items[1])
  assert(view.render_cache == nil, "earlier item invalidation retained the stable cache")
  local full_write
  vim.api.nvim_buf_set_lines = function(target, first, last, strict, lines)
    if target == buf then
      full_write = { first = first, last = last }
    end
    return original_set_lines(target, first, last, strict, lines)
  end
  ok, err = pcall(function()
    view:render()
  end)
  vim.api.nvim_buf_set_lines = original_set_lines
  assert(ok, err)
  assert(
    full_write and full_write.first == 0 and full_write.last == -1,
    "cache invalidation did not force a full render"
  )

  local cache_key = view.render_cache.key
  fixture.state.hide_thinking = true
  view:render()
  assert(view.render_cache.key ~= cache_key, "global view state did not invalidate the render cache")
  cache_key = view.render_cache.key
  vim.api.nvim_win_set_width(fixture.win, 52)
  view:render()
  assert(view.render_cache.key ~= cache_key, "window width did not invalidate the render cache")
end)

with_view({}, function(fixture)
  fixture.view:ensure_buffer()
  local renders = 0
  fixture.view._render_transcript = function()
    renders = renders + 1
  end
  fixture.view:schedule_render()
  fixture.view:schedule_render()
  fixture.view:schedule_render()
  assert(fixture.view.render_pending, "scheduled render did not mark pending work")
  assert(
    vim.wait(500, function()
      return renders == 1
    end, 10),
    "coalesced render timer did not run"
  )
  assert(not fixture.view.render_pending and fixture.view.render_timer == nil, "render timer did not settle")
end)

with_view({}, function(fixture)
  fixture.view:ensure_buffer()
  local renders = 0
  fixture.view._render_transcript = function()
    renders = renders + 1
  end
  fixture.view:schedule_render()
  fixture.view:destroy()
  assert(fixture.view.render_timer == nil, "destroyed view retained its scheduled render timer")
  fixture.view:schedule_render()
  assert(renders == 0 and not fixture.view.render_pending, "destroyed view executed or accepted scheduled work")
end)

with_view({}, function(fixture)
  local buf = fixture.view:ensure_buffer()
  local renders = 0
  fixture.view._render_transcript = function()
    renders = renders + 1
  end
  fixture.view:schedule_render()
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(
    vim.wait(500, function()
      return not fixture.view.render_pending
    end, 10),
    "wiped-buffer timer did not settle"
  )
  assert(renders == 0 and fixture.view.render_timer == nil, "wiped buffer accepted scheduled rendering")
end)

local scroll_items = {}
for index = 1, 24 do
  table.insert(scroll_items, { type = "status", _pi_id = "status:" .. index, text = "line " .. index })
end
with_view({ items = scroll_items }, function(fixture)
  local view = fixture.view
  local _, win = fixture:open(32, 6)
  view:render()
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(view.buf), 0 })
  table.insert(scroll_items, { type = "status", _pi_id = "status:25", text = "followed output" })
  view:render()
  assert(vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(view.buf), "bottom follow was lost")

  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  table.insert(scroll_items, { type = "status", _pi_id = "status:26", text = "preserved output" })
  fixture.state.overlay_height = 2
  view:render()
  assert(vim.api.nvim_win_get_cursor(win)[1] == 3, "scrolled-up cursor was not preserved")

  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(view.buf), 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  assert(view:clamp(), "blank space below the transcript was not clamped")
  vim.api.nvim_win_set_width(win, 20)
  vim.api.nvim_win_set_height(win, 3)
  view:render()
  vim.api.nvim_win_close(win, true)
  fixture.win = nil
  assert(not view:clamp(), "closed window was treated as a valid scroll owner")
end)

with_view({}, function(fixture)
  local buf, win = fixture:open(40, 8)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five", "six", "seven" })
  vim.bo[buf].modifiable = false
  local tool = { id = "tool" }
  local process = { first = 5, last = 5, id = "process" }
  local image = { row = 1, col = 1, width = 4, height = 2, range_height = 2, id = "image" }
  fixture.view.tool_ranges = { { first = 2, last = 4, item = tool } }
  fixture.view.process_ranges = { process }
  fixture.view.image_placements = { image }
  assert(
    fixture.view:tool_at_row(2) == tool and fixture.view:tool_at_row(4) == tool,
    "tool hit testing lost an inclusive range boundary"
  )
  assert(
    fixture.view:tool_at_row(1) == nil and fixture.view:process_at_row(5) == process,
    "tool/process hit testing crossed structured range boundaries"
  )
  assert(
    fixture.view:image_at_row(2) == image and fixture.view:image_at_row(3) == image,
    "image hit testing lost an inclusive placement boundary"
  )
  assert(fixture.view:image_at_row(4) == nil, "image row hit escaped its inclusive bounds")
  local original_screenpos = vim.fn.screenpos
  vim.fn.screenpos = function()
    return { row = 10, col = 20, endcol = 20, curscol = 20 }
  end
  local hit_ok, hit = pcall(fixture.view.image_at_mouse, fixture.view, {
    winid = win,
    line = 2,
    screenrow = 10,
    screencol = 20,
  })
  vim.fn.screenpos = original_screenpos
  assert(hit_ok, hit)
  assert(hit == image, "mouse coordinates did not hit the image descriptor")
  assert(fixture.view:image_at_mouse({ winid = win + 1000, line = 2 }) == nil, "foreign window hit was accepted")
  fixture.view:clear()
  assert(
    not fixture.view:tool_at_row(2) and not fixture.view:process_at_row(5) and not fixture.view:image_at_row(2),
    "TranscriptView clear retained structured hit ranges"
  )
end)

with_view({}, function(fixture)
  local first = { type = "image", mimeType = "image/png" }
  local second = { type = "image", mimeType = "image/png" }
  fixture.items[1] = { type = "user", content = { first, first } }
  fixture.items[2] = { type = "tool", result = { content = { second } } }
  local original_prepare = image_data.prepare
  local original_prepare_preview = image_data.prepare_preview
  local prepared = {}
  local callbacks = {}
  image_data.prepare = function(block, width)
    table.insert(prepared, { block = block, width = width })
    return { key = tostring(block), width = 1, height = 1 }
  end
  image_data.prepare_preview = function(block, callback)
    table.insert(callbacks, { block = block, callback = callback })
  end
  local scheduled = 0
  fixture.view._schedule_render = function()
    scheduled = scheduled + 1
  end
  local ok, err = pcall(function()
    fixture.view:_prepare_images(40, 1, true)
  end)
  image_data.prepare = original_prepare
  image_data.prepare_preview = original_prepare_preview
  assert(ok, err)
  assert(
    #prepared == 2 and prepared[1].block == first and prepared[2].block == second,
    "images were not prepared once in order"
  )
  assert(prepared[1].width == 34 and prepared[2].width == 34, "view width was not passed to image preparation")
  assert(#fixture.observed.tracked == 2 and #callbacks == 2, "image tracking or preview preparation was not coalesced")
  assert(#fixture.observed.refreshed == 2, "prepared image accounting was not refreshed")
  callbacks[1].callback()
  assert(#fixture.observed.refreshed == 3 and scheduled == 1, "current image callback did not refresh the view")

  image_data.prepare = function()
    return { key = "next", width = 1, height = 1 }
  end
  image_data.prepare_preview = function(_, callback)
    table.insert(callbacks, { callback = callback })
  end
  fixture.view:_prepare_images(40, 1, true)
  image_data.prepare = original_prepare
  image_data.prepare_preview = original_prepare_preview
  local stale = callbacks[#callbacks].callback
  fixture.view:invalidate()
  stale()
  assert(#fixture.observed.refreshed == 5 and scheduled == 1, "stale image callback changed invalidated view state")
  fixture.view:destroy()
  stale()
  assert(#fixture.observed.refreshed == 5 and scheduled == 1, "late image callback changed destroyed view state")
end)

local function prepared_image(digest)
  return {
    type = "image",
    mimeType = "image/png",
    _pi_image = {
      token = 0,
      mime_type = "image/png",
      source = {
        digest = digest,
        path = "/tmp/" .. digest .. ".png",
        mime_type = "image/png",
        pixel_width = 8,
        pixel_height = 4,
        description = "[Image: image/png, 8x4]",
      },
    },
  }
end

local first_terminal_image = prepared_image("first")
local second_terminal_image = prepared_image("second")
with_view({
  terminal = true,
  items = {
    {
      type = "user",
      _pi_id = "image-user",
      text = "",
      content = { first_terminal_image, second_terminal_image },
    },
  },
}, function(fixture)
  fixture:open(48, 10)
  fixture.view:render()
  local sync = fixture.backend.sync_calls[#fixture.backend.sync_calls]
  assert(sync and #sync.placements == 2, "terminal image descriptors were not sent to the backend")
  assert(
    sync.placements[1].block == first_terminal_image and sync.placements[2].block == second_terminal_image,
    "terminal image placement order diverged from structured content order"
  )
  assert(sync.placements[1].row < sync.placements[2].row, "terminal image descriptors lost visible order")
  assert(sync.placements[1].width > 0 and sync.placements[1].width <= 42, "terminal image width escaped layout bounds")
  assert(
    fixture.view:image_at_row(sync.placements[1].row + 1) == sync.placements[1],
    "rendered terminal placement was not available to image hit testing"
  )
end)

with_view(
  { backend = false, items = { { type = "user", text = "", content = { { type = "image" } } } } },
  function(fixture)
    local buf = fixture:open(40, 8)
    fixture.view:render()
    assert(
      table.concat(buffer_lines(buf), "\n"):find("[Image:", 1, true),
      "missing backend did not render a text fallback"
    )
  end
)

print("transcript_view_spec: ok")
