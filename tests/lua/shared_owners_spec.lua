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
  ["1250"] = "1.2k",
  ["10000"] = "10k",
  ["1200000"] = "1.2M",
  ["10000000"] = "10M",
  invalid = "0",
}
for value, expected in pairs(compact_cases) do
  assert(format.compact_count(value) == expected, ("compact count failed for %s"):format(value))
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
