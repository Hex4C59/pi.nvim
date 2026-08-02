local Parser = require("pi.protocol").Parser

local received = {}
local errors = {}
local parser = Parser.new({
  on_message = function(message)
    table.insert(received, message)
  end,
  on_error = function(err)
    table.insert(errors, err)
  end,
  max_frame_bytes = 128,
})

local encoded = vim.json.encode({ type = "message_update", text = "你好" })
local split = encoded:find("你", 1, true) + 1
parser:push(encoded:sub(1, split))
assert(#received == 0, "partial UTF-8 frame must not be decoded")
parser:push(encoded:sub(split + 1) .. "\n")
assert(received[1].text == "你好", "fragmented UTF-8 frame was not reconstructed")

parser:push("{\"type\":\"one\"}\n{\"type\":\"two\"}\r\n")
assert(received[2].type == "one", "first frame in a chunk was lost")
assert(received[3].type == "two", "CRLF frame was not accepted")

local separator = "\226\128\168"
parser:push("{\"type\":\"unicode\",\"text\":\"a" .. separator .. "b\"}\n")
assert(received[4].text == "a" .. separator .. "b", "Unicode line separator must not split JSONL")

parser:push("not-json\n")
assert(#errors == 1, "malformed JSON must report an error")

parser:push(string.rep("x", 129))
assert(#errors == 2, "oversized frames must report an error")

local trailing = Parser.new({
  on_message = function(message)
    table.insert(received, message)
  end,
  on_error = function(err)
    table.insert(errors, err)
  end,
})
trailing:push("{\"type\":\"eof\"}")
trailing:finish()
assert(received[5].type == "eof", "final frame at EOF was not decoded")

print("protocol_spec: ok")
