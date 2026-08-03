local code = require("pi.ui.render.code")
local renderer = require("pi.ui.render")

local function render_markdown(source, opts)
  return renderer.render({
    {
      type = "assistant",
      _pi_id = "assistant:markdown",
      message = { content = { { type = "text", text = source } } },
    },
  }, vim.tbl_extend("force", { width = 80 }, opts or {}))
end

local function highlight_set(marks)
  local result = {}
  for _, mark in ipairs(marks) do
    if mark.highlight then
      result[mark.highlight] = true
    end
  end
  return result
end

local lua_parser_available = pcall(function()
  local parser = vim.treesitter.get_string_parser("local value = true", "lua")
  assert(parser:parse()[1])
  assert(vim.treesitter.query.get("lua", "highlights"))
end)

local markdown_source =
  "# Result\n\n**Overview**\n\nRead [lua/example.lua](/tmp/lua/example.lua), use `ready`, then **verify**.\n\n- first item\n\n> quoted\n\n```lua\nlocal value = true\n```"
local lines, marks = render_markdown(markdown_source)
local text = table.concat(lines, "\n")
assert(text:find(" Result", 1, true), "Markdown heading was not rendered")
assert(not text:find("# Result", 1, true), "Markdown heading marker leaked into the transcript")
assert(text:find(" Overview", 1, true), "strong section heading was not rendered")
assert(not text:find("**Overview**", 1, true), "strong section marker leaked into the transcript")
assert(text:find("Read lua/example.lua, use ready, then verify.", 1, true), "inline Markdown is unreadable")
assert(not text:find("/tmp/lua/example.lua", 1, true), "Markdown link target leaked into the transcript")
assert(text:find("- first item", 1, true), "Markdown list item is missing")
assert(text:find(" │ quoted", 1, true), "Markdown quote is missing")
assert(text:find(" local value = true", 1, true), "fenced code content is missing")

local code_row
for row, line in ipairs(lines) do
  if line:find("local value = true", 1, true) then
    code_row = row
    break
  end
end
assert(code_row, "fenced code row is missing")
assert(vim.fn.strdisplaywidth(lines[code_row]) == 79, "code surface lost its right margin")
local code_surface
for _, mark in ipairs(marks) do
  if mark.row == code_row - 1 and mark.highlight == "PiCodeBg" then
    code_surface = mark
  end
  assert(mark.line_highlight ~= "PiCodeBg", "code surface still uses full-line highlighting")
end
assert(code_surface and code_surface.start_col == 1, "code surface lost its left margin")

local highlights = highlight_set(marks)
for _, group in ipairs({
  "PiMarkdownHeading",
  "PiMarkdownCode",
  "PiMarkdownStrong",
  "PiMarkdownInlineCode",
  "PiMarkdownLink",
  "PiMarkdownListMarker",
}) do
  assert(highlights[group], "Markdown semantic highlight is missing: " .. group)
end
if lua_parser_available then
  assert(highlights["@keyword.lua"], "Lua keyword syntax highlight is missing")
  assert(highlights["@boolean.lua"], "Lua boolean syntax highlight is missing")
end

local soft_break_lines = render_markdown(
  "我会沿 client ->\nruntime -> `render/UI` -> extensions\n逐层检查。\n\n显式硬换行  \n必须另起一行"
)
local soft_break_text = table.concat(soft_break_lines, "\n")
assert(
  soft_break_text:find("我会沿 client -> runtime -> render/UI -> extensions 逐层检查。", 1, true),
  "Markdown soft breaks must remain in one logical row"
)
assert(
  soft_break_text:find("显式硬换行\n   必须另起一行", 1, true),
  "Markdown hard breaks must remain separate rows"
)

local paragraph_lines = render_markdown("first paragraph\n\nsecond paragraph")
assert(
  #paragraph_lines == 3
    and vim.trim(paragraph_lines[1]) == "first paragraph"
    and vim.trim(paragraph_lines[2]) == ""
    and vim.trim(paragraph_lines[3]) == "second paragraph",
  "blank line no longer separates Markdown paragraphs"
)
local adjacent_lines, adjacent_marks = render_markdown("**strong**`code`[label](https://example.test/target)")
assert(table.concat(adjacent_lines, "\n"):find("strongcodelabel", 1, true), "adjacent inline tokens were reordered")
local adjacent_highlights = highlight_set(adjacent_marks)
assert(
  adjacent_highlights.PiMarkdownStrong
    and adjacent_highlights.PiMarkdownInlineCode
    and adjacent_highlights.PiMarkdownLink,
  "adjacent inline token highlights are incomplete"
)
local unmatched_lines = render_markdown("Keep **unmatched and `punctuation as written")
assert(
  table.concat(unmatched_lines, "\n"):find("Keep **unmatched and `punctuation as written", 1, true),
  "unmatched Markdown punctuation was discarded"
)

local empty_fence_lines, empty_fence_marks = render_markdown("```lua\n```")
assert(#empty_fence_lines >= 2, "empty fenced block lost its code surface")
assert(highlight_set(empty_fence_marks).PiCodeBg, "empty fenced block lost its fallback surface")
local fallback_lines, fallback_marks = render_markdown("```language-without-a-parser\nplain fallback\n```")
assert(table.concat(fallback_lines, "\n"):find("plain fallback", 1, true), "unknown code language did not render")
assert(highlight_set(fallback_marks).PiMarkdownCode, "unknown code language lost its fallback highlight")

assert(code.normalize_language("js") == "javascript", "JavaScript language alias changed")
assert(code.normalize_language("shell") == "bash", "shell language alias changed")
assert(code.normalize_language("plaintext") == nil, "plain-text fence unexpectedly requests a parser")
assert(code.language_for_path("lua/pi/init.lua") == "lua", "code language inference from a Lua path changed")

local long_word = string.rep("x", 64)
local narrow_lines = render_markdown(long_word, { width = 20 })
assert(#narrow_lines == 1 and narrow_lines[1]:find(long_word, 1, true), "narrow Markdown corrupted a long word")
assert(vim.fn.strdisplaywidth(narrow_lines[1]) > 20, "long word no longer relies on window wrapping")

local cjk_lines, cjk_marks = render_markdown("查看[界面](https://example.test/ui)状态")
local cjk_link
for _, mark in ipairs(cjk_marks) do
  if mark.highlight == "PiMarkdownLink" then
    cjk_link = mark
    break
  end
end
assert(cjk_link, "CJK Markdown link highlight is missing")
local cjk_line = cjk_lines[cjk_link.row + 1]
assert(cjk_link.end_col <= #cjk_line, "CJK Markdown mark exceeds its byte row")
assert(cjk_line:sub(cjk_link.start_col + 1, cjk_link.end_col) == "界面", "CJK Markdown byte columns changed")

local crlf_lines = render_markdown("first\r\nsecond\r\n\r\nthird")
assert(
  #crlf_lines == 3
    and vim.trim(crlf_lines[1]) == "first second"
    and vim.trim(crlf_lines[2]) == ""
    and vim.trim(crlf_lines[3]) == "third",
  "CRLF Markdown input was not normalized"
)
for _, rendered_line in ipairs(crlf_lines) do
  assert(not rendered_line:find("[\r\n]"), "Markdown renderer emitted an embedded newline")
end

local media_block = {
  type = "image",
  mimeType = "image/png",
  path = "/tmp/render-media.png",
  _pi_image = {
    mime_type = "image/png",
    prepared = {
      key = "fixture-image",
      path = "/tmp/render-media.png",
      width = 8,
      height = 4,
      description = "[Image: image/png 8x4]",
    },
  },
}
local media_item = {
  type = "assistant",
  _pi_id = "assistant:media",
  message = { content = { media_block } },
}
local media_item_copy = vim.deepcopy(media_item)
local media_lines, _, _, _, placements = renderer.render({ media_item }, { width = 40, image_terminal = true })
assert(#placements == 1, "prepared media block did not emit exactly one placement")
local placement = placements[1]
assert(placement.block == media_block, "media placement lost source block identity")
assert(placement.path == media_block.path, "media placement changed its source path")
assert(placement.row >= 0 and media_lines[placement.row + 1], "media placement row is invalid")
assert(placement.key == "assistant:media:1:fixture-image", "media placement identity changed")
assert(vim.deep_equal(media_item, media_item_copy), "media descriptor rendering mutated its input message")

local invalid_media = {
  type = "assistant",
  message = { content = { { type = "image", mimeType = "image/unsupported" } } },
}
local invalid_lines, _, _, _, invalid_placements = renderer.render({ invalid_media }, {
  width = 40,
  image_terminal = true,
})
assert(#invalid_placements == 0, "unsupported media source emitted a placement")
assert(
  table.concat(invalid_lines, "\n"):find("[Image: image/unsupported]", 1, true),
  "unsupported media source lost its text fallback"
)

print("render_markdown_spec: ok")
