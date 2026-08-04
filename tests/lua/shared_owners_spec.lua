local catalog = require("pi.commands.catalog")
local format = require("pi.format")
local message = require("pi.message")

assert(message.text_content("plain") == "plain", "string message content changed")
assert(message.text_content(nil) == "", "missing message content must be empty")
assert(message.text_content({
  { type = "text", text = "first" },
  { type = "image", data = "ignored" },
  { type = "text", text = "second" },
}) == "first\nsecond", "text blocks were not concatenated in order")
assert(message.text_content({ { type = "image" } }) == "", "image-only content produced text")

local compact_cases = {
  ["950"] = "950",
  ["1249"] = "1.2k",
  ["1250"] = "1.2k",
  ["1251"] = "1.3k",
  ["1350"] = "1.4k",
  ["1450"] = "1.4k",
  ["9950"] = "10.0k",
  ["10000"] = "10k",
  ["1249999"] = "1.2M",
  ["1250000"] = "1.2M",
  ["1350000"] = "1.4M",
  ["1200000"] = "1.2M",
  ["10000000"] = "10M",
  invalid = "0",
}
for value, expected in pairs(compact_cases) do
  assert(format.compact_count(value) == expected, ("compact count failed for %s"):format(value))
end

assert(format.truncate_display("abc", 3) == "abc", "display truncation changed exact-width ASCII")
assert(format.truncate_display("abcd", 3) == "...", "display truncation did not reserve the ASCII suffix")
assert(format.truncate_display("abcdef", 5, "..") == "abc..", "custom display suffix changed")
for _, case in ipairs({
  { value = "中文中文", width = 7 },
  { value = "🙂🙂🙂", width = 7 },
  { value = "e\204\129e\204\129e\204\129", width = 5 },
  { value = "👩‍💻 work", width = 6 },
}) do
  local truncated = format.truncate_display(case.value, case.width)
  assert(pcall(vim.str_utfindex, truncated), "display truncation produced invalid UTF-8")
  assert(vim.fn.strdisplaywidth(truncated) <= case.width, "display truncation exceeded its cell budget")
end

local first = catalog.builtin_commands()
local second = catalog.builtin_commands()
assert(first ~= second and first[1] ~= second[1], "built-in catalogue did not return fresh tables")
first[1].name = "mutated"
assert(second[1].name == "settings", "catalogue mutation leaked into a later read")

local merged = catalog.merge({
  { name = "model", description = "must not replace built-in" },
  { name = "fixture", description = "dynamic command" },
  { name = "fixture", description = "duplicate dynamic command" },
})
local model_count = 0
local fixture_count = 0
for _, command in ipairs(merged) do
  model_count = model_count + (command.name == "model" and 1 or 0)
  fixture_count = fixture_count + (command.name == "fixture" and 1 or 0)
end
assert(model_count == 1 and fixture_count == 1, "catalogue merge did not deduplicate by name")
assert(merged[#merged].name == "fixture", "dynamic command order changed")

print("shared_owners_spec: ok")
