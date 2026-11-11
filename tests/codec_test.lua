local t = require "tests.helper"
local codec = require "src.codec"
local takes = require "src.takes"

local function sample()
  local one = takes.new_content()
  one.notes[1] = { [1] = { 48, 0, 0x40, 255, 0x5A, 0, 0 }, [2] = { 52, 0, 255, 255, 0, 0, 0 } }
  one.notes[9] = { [1] = { 120, 255, 255, 255, 0, 0, 0 } }
  one.fx[3] = { [1] = { 0x0A, 0x20 } }
  one.auto["2:1"] = {
    device = 2,
    param = 1,
    playmode = 2,
    name = "Analog Filter",
    points = { { 1, 0.25, 0 }, { 8.5, 0.75, 0 } },
  }
  one.auto["3:2"] = { device = 3, param = 2, playmode = 1, points = { { 4, 0.5, 0 } } }
  local two = takes.new_content()
  two.notes[5] = { [1] = { 60, 1, 255, 255, 0, 0, 0 } }
  return {
    track = 3,
    next_id = 3,
    link = false,
    solo = 2,
    slots = { { seq = 2, pattern = 5, lines = 16 }, { seq = 3, pattern = 9, lines = 64 } },
    base = { ["2:1"] = 0.5 },
    takes = {
      { id = 1, rows = 80, content = one },
      { id = 2, rows = 80, content = two, overlapped = true },
    },
    comp = {
      notes = { { from = 1, to = 16, take = 1 }, { from = 17, to = 80, take = 2 } },
      moves = { { from = 1, to = 80, take = 1 } },
    },
  }
end

local text = codec.encode(sample())
t.check(text:sub(1, 7) == "TAKES 1", "encode: starts with the header")
t.check(text:sub(-4) == "end\n", "encode: ends with the end line")
t.eq(codec.encode(sample()), text, "encode: the same data gives the same text")

local data, err = codec.decode(text)
t.eq(err, nil, "decode: no error")
assert(data)
t.eq(data.track, 3, "decode: track")
t.eq(data.next_id, 3, "decode: next id")
t.eq(data.link, false, "decode: link")
t.eq(data.solo, 2, "decode: solo")
t.eq(#data.slots, 2, "decode: slots")
t.eq(data.slots[2].lines, 64, "decode: slot lines")
t.eq(data.base["2:1"], 0.5, "decode: base value")
t.eq(#data.takes, 2, "decode: takes")
t.check(
  takes.equal(data.takes[1].content, sample().takes[1].content),
  "decode: take 1 content is equal"
)
t.check(
  takes.equal(data.takes[2].content, sample().takes[2].content),
  "decode: take 2 content is equal"
)
t.eq(data.takes[1].content.auto["2:1"].name, "Analog Filter", "decode: device name with a space")
t.eq(data.takes[1].content.auto["3:2"].name, nil, "decode: an envelope without a device name")
t.eq(data.takes[2].overlapped, true, "decode: overlapped flag")
t.eq(data.takes[1].overlapped, nil, "decode: no overlapped flag")
t.eq(data.comp.notes[2].take, 2, "decode: notes segment")
t.eq(data.comp.moves[1].to, 80, "decode: moves segment")
t.eq(codec.encode(data), text, "round trip: encode(decode(text)) is the text")

-- Bad input never raises an error and never runs code.
local _, e = codec.decode(nil)
t.eq(e, "no data", "decode: nil")
_, e = codec.decode "os.exit(1)"
t.eq(e, "not a takes session", "decode: Lua code is not run")
_, e = codec.decode(text:sub(1, #text - 4))
t.eq(e, "the data is cut off", "decode: cut off at a line end")
data, e = codec.decode(text:sub(1, #text - 10))
t.check(data == nil and e ~= nil, "decode: cut off inside a line")
_, e = codec.decode(text:gsub("TAKES 1", "TAKES 99"))
t.eq(e, "made by a newer version (99)", "decode: newer version")
_, e = codec.decode(text:gsub("track 3", "track x"))
t.check(e and e:find "bad number", "decode: bad number")
_, e = codec.decode "TAKES 1\nend\n"
t.eq(e, "the data has no track or no loop", "decode: empty session")
data = codec.decode(text:gsub("track 3", "future thing 1 2 3\ntrack 3"))
t.check(data and data.track == 3, "decode: unknown lines are skipped")

t.done()
