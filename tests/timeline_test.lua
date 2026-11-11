local t = require "tests.helper"
local timeline = require "src.timeline"

-- One looped pattern.
local one = timeline.new { { seq = 3, pattern = 7, lines = 64 } }
t.eq(one.total, 64, "one slot: total rows")
t.eq(timeline.row_of(one, 3, 1), 1, "one slot: first line")
t.eq(timeline.row_of(one, 3, 64), 64, "one slot: last line")
t.eq(timeline.row_of(one, 3, 65), nil, "one slot: line past the end")
t.eq(timeline.row_of(one, 4, 1), nil, "one slot: other sequence position")
local halves = timeline.chunks(one)
t.eq(#halves, 2, "one slot: two chunks")
t.eq(halves[1].to, 32, "one slot: first half ends at the middle")
t.eq(halves[2].from, 33, "one slot: second half starts after the middle")
t.eq(halves[2].to, 64, "one slot: second half ends at the end")

-- Three patterns of different lengths.
local three = timeline.new {
  { seq = 2, pattern = 5, lines = 16 },
  { seq = 3, pattern = 9, lines = 64 },
  { seq = 4, pattern = 6, lines = 32 },
}
t.eq(three.total, 112, "three slots: total rows")
t.eq(timeline.row_of(three, 3, 1), 17, "three slots: second slot starts after the first")
t.eq(timeline.row_of(three, 4, 32), 112, "three slots: last row")
local slot, line = timeline.locate(three, 17)
t.eq(slot, 2, "locate: slot")
t.eq(line, 1, "locate: line")
slot, line = timeline.locate(three, 112)
t.eq(slot, 3, "locate: last slot")
t.eq(line, 32, "locate: last line")
t.eq(timeline.locate(three, 113), nil, "locate: past the end")
local chunks = timeline.chunks(three)
t.eq(#chunks, 3, "three slots: one chunk per slot")
t.eq(chunks[2].from, 17, "three slots: chunk 2 from")
t.eq(chunks[2].to, 80, "three slots: chunk 2 to")

local spans = timeline.spans(three, 10, 90)
t.eq(#spans, 3, "spans: a range over three slots")
t.eq(spans[1].from_line, 10, "spans: first from")
t.eq(spans[1].to_line, 16, "spans: first to")
t.eq(spans[2].first_row, 17, "spans: second first row")
t.eq(spans[2].to_line, 64, "spans: second to")
t.eq(spans[3].to_line, 10, "spans: third to")
t.eq(#timeline.spans(three, 20, 30), 1, "spans: a range inside one slot")

t.check(
  timeline.same(
    three,
    timeline.new {
      { seq = 2, pattern = 5, lines = 16 },
      { seq = 3, pattern = 9, lines = 64 },
      { seq = 4, pattern = 6, lines = 32 },
    }
  ),
  "same: equal slots"
)
t.check(not timeline.same(one, three), "same: different slots")
t.fails(function()
  timeline.new {}
end, "at least one slot", "new: no slots")

t.done()
