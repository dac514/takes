local t = require "tests.helper"
local passes = require "src.passes"
local timeline = require "src.timeline"

---Run the state machine over a list of rows and collect the actions as text.
local function run(state, rows)
  local out = {}
  for _, row in ipairs(rows) do
    for _, a in ipairs(passes.step(state, row)) do
      if a.kind == "harvest" then
        out[#out + 1] = ("%d:h%d@%d%s"):format(a.pass, a.chunk, row, a.overlapped and "!" or "")
      else
        out[#out + 1] = ("%d:close@%d"):format(a.pass, row)
      end
    end
  end
  return table.concat(out, " ")
end

local function range(a, b, step)
  local out = {}
  for i = a, b, step or 1 do
    out[#out + 1] = i
  end
  return out
end

local function join(...)
  local out = {}
  for _, list in ipairs { ... } do
    for _, v in ipairs(list) do
      out[#out + 1] = v
    end
  end
  return out
end

local function texts(actions)
  local out = {}
  for _, a in ipairs(actions) do
    out[#out + 1] = a.kind == "harvest" and ("%d:h%d"):format(a.pass, a.chunk)
      or ("%d:close"):format(a.pass)
  end
  return table.concat(out, " ")
end

local one = timeline.new { { seq = 1, pattern = 1, lines = 64 } }
local halves = timeline.chunks(one)

-- A normal pass: every row is seen.
local s = passes.new(64, halves, 2, 1)
t.eq(
  run(s, join(range(1, 64), range(1, 64), range(1, 10))),
  "0:h1@34 0:h2@2 0:close@2 1:h1@34 1:h2@2 1:close@2",
  "normal: the head is read after the middle, the tail after the wrap"
)

-- The timer skips rows.
s = passes.new(64, halves, 2, 1)
t.eq(run(s, { 1, 9, 30, 41, 60, 5, 40 }), "0:h1@41 0:h2@5 0:close@5 1:h1@40", "skipped rows")

-- The timer stalls from row 20 to row 10 of the next pass: both chunks are due.
s = passes.new(64, halves, 2, 1)
t.eq(
  run(s, { 1, 20, 10 }),
  "0:h1@10! 0:h2@10 0:close@10",
  "stall over the wrap: the head is flagged"
)

-- Recording starts in the second half.
s = passes.new(64, halves, 2, 40)
t.eq(run(s, { 40, 41 }), "0:h1@40", "start in the second half: the head is read at once")
t.eq(
  run(s, { 64, 1, 2, 3 }),
  "0:h2@2 0:close@2",
  "start in the second half: the tail closes pass 0"
)

-- Stop in the middle of a pass.
s = passes.new(64, halves, 2, 1)
run(s, range(1, 20))
t.eq(texts(passes.finish(s)), "0:h1 0:close", "stop in the first half: one partial pass")
s = passes.new(64, halves, 2, 1)
run(s, range(1, 50))
t.eq(
  texts(passes.finish(s)),
  "0:h2 0:close",
  "stop in the second half: the tail is read and the pass closed"
)
s = passes.new(64, halves, 2, 1)
run(s, join(range(1, 64), { 1 }))
t.eq(
  texts(passes.finish(s)),
  "0:h2 0:close 1:h1 1:close",
  "stop just after the wrap: two passes close"
)
t.eq(texts(passes.finish(s)), "", "finish twice gives nothing new")

-- A 16 line pattern.
local small = timeline.new { { seq = 1, pattern = 1, lines = 16 } }
s = passes.new(16, timeline.chunks(small), 2, 1)
t.eq(run(s, join(range(1, 16), range(1, 4))), "0:h1@10 0:h2@2 0:close@2", "16 lines")

-- Three patterns of different lengths: one chunk per pattern.
local three = timeline.new {
  { seq = 1, pattern = 1, lines = 16 },
  { seq = 2, pattern = 2, lines = 64 },
  { seq = 3, pattern = 3, lines = 32 },
}
s = passes.new(three.total, timeline.chunks(three), 2, 1)
t.eq(
  run(s, join(range(1, 112), range(1, 20))),
  "0:h1@18 0:h2@82 0:h3@2 0:close@2 1:h1@18",
  "three patterns: each one is read when the playhead is in the next"
)

-- A close says if the playhead reached the end of the pass.
local function closes(actions)
  local out = {}
  for _, a in ipairs(actions) do
    if a.kind == "close" then
      out[#out + 1] = ("%d:%s"):format(a.pass, a.complete and "complete" or "cut")
    end
  end
  return table.concat(out, " ")
end
s = passes.new(64, halves, 8, 1)
local seen = {}
for _, row in ipairs(join(range(1, 64), range(1, 10))) do
  for _, a in ipairs(passes.step(s, row)) do
    seen[#seen + 1] = a
  end
end
t.eq(closes(seen), "0:complete", "close from step: the pass is complete")
s = passes.new(64, halves, 8, 1)
run(s, join(range(1, 64), range(1, 4)))
t.eq(
  closes(passes.finish(s)),
  "0:complete 1:cut",
  "stop just after the wrap: the wrapped pass is complete, the new one is cut"
)
s = passes.new(64, halves, 8, 1)
run(s, range(1, 50))
t.eq(closes(passes.finish(s)), "0:cut", "stop before the end: the pass is cut")

t.eq(passes.current_pass(passes.new(64, halves, 2, 1)), 0, "current pass at the start")
s = passes.new(64, halves, 2, 1)
run(s, join(range(1, 64), range(1, 5)))
t.eq(passes.current_pass(s), 1, "current pass after one wrap")

t.done()
