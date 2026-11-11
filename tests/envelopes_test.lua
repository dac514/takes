local t = require "tests.helper"
local envelopes = require "src.envelopes"

local function env(playmode, points)
  return { device = 2, param = 1, playmode = playmode, points = points }
end

local function near(a, b)
  return a ~= nil and math.abs(a - b) < 1e-6
end

local function text(e)
  local out = {}
  for _, p in ipairs(e.points) do
    out[#out + 1] = ("%.2f=%.2f"):format(p[1], p[2])
  end
  return table.concat(out, " ")
end

t.eq(envelopes.key(2, 1), "2:1", "key")

-- value_at
local lines = env(envelopes.PLAYMODE_LINES, { { 1, 0 }, { 9, 1 }, { 17, 0.5 } })
t.check(near(envelopes.value_at(lines, 1), 0), "lines: at the first point")
t.check(near(envelopes.value_at(lines, 5), 0.5), "lines: half way")
t.check(near(envelopes.value_at(lines, 13), 0.75), "lines: second span")
t.check(near(envelopes.value_at(lines, 30), 0.5), "lines: after the last point")
t.eq(
  envelopes.value_at(env(envelopes.PLAYMODE_LINES, { { 5, 1 } }), 2),
  nil,
  "before the first point"
)
local steps = env(envelopes.PLAYMODE_POINTS, { { 1, 0.2 }, { 9, 0.8 } })
t.check(near(envelopes.value_at(steps, 8.9), 0.2), "points: holds the last value")
t.check(near(envelopes.value_at(steps, 9), 0.8), "points: steps at the point")

-- copy_range
local dst = { ["2:1"] = env(2, { { 1, 0 }, { 5, 0.5 }, { 20, 1 } }) }
local src = { ["2:1"] = env(2, { { 6, 0.9 }, { 12, 0.1 }, { 30, 0.3 } }) }
envelopes.copy_range(dst, src, 4, 16)
t.eq(
  text(dst["2:1"]),
  "1.00=0.00 6.00=0.90 12.00=0.10 20.00=1.00",
  "copy_range: replaces the points in the range"
)
envelopes.copy_range(dst, {}, 1, 64)
t.eq(dst["2:1"], nil, "copy_range: an envelope with no point left is removed")
local fresh = {}
envelopes.copy_range(fresh, src, 1, 16)
t.eq(text(fresh["2:1"]), "6.00=0.90 12.00=0.10", "copy_range: creates the envelope")
fresh["2:1"].points[1][2] = 0
t.check(near(src["2:1"].points[1][2], 0.9), "copy_range: the copy does not share points")

-- equal
t.check(
  envelopes.equal(src, { ["2:1"] = env(2, { { 6, 0.9004 }, { 12.001, 0.1 }, { 30, 0.3 } }) }),
  "equal: within rounding"
)
t.check(
  not envelopes.equal(src, { ["2:1"] = env(2, { { 6, 0.8 }, { 12, 0.1 }, { 30, 0.3 } }) }),
  "equal: different value"
)
t.check(not envelopes.equal(src, {}), "equal: missing envelope")
t.check(not envelopes.equal({}, src), "equal: extra envelope")

-- render: a cut between two takes with line envelopes.
local up = { ["2:1"] = env(2, { { 1, 0 }, { 17, 1 } }) } -- rises over 16 rows
local down = { ["2:1"] = env(2, { { 1, 1 }, { 17, 0 } }) } -- falls over 16 rows
local out =
  envelopes.render({ { from = 1, to = 8, auto = up }, { from = 9, to = 16, auto = down } }, 16)
local e = out["2:1"]
t.check(near(envelopes.value_at(e, 1), 0), "render: starts with the first take")
t.check(near(envelopes.value_at(e, 5), 0.25), "render: the first take keeps its slope")
t.check(
  math.abs(envelopes.value_at(e, 9 - envelopes.TIME_QUANTUM) - 0.5) < 0.01,
  "render: the first take ends at its own value"
)
t.check(near(envelopes.value_at(e, 9), 0.5), "render: the second take starts at its own value")
t.check(near(envelopes.value_at(e, 13), 0.25), "render: the second take keeps its slope")

-- render: step envelopes need no end point.
local s1 = { ["2:1"] = env(1, { { 1, 0.2 }, { 12, 0.9 } }) }
local s2 = { ["2:1"] = env(1, { { 1, 0.7 } }) }
out = envelopes.render({ { from = 1, to = 8, auto = s1 }, { from = 9, to = 16, auto = s2 } }, 16)
t.eq(text(out["2:1"]), "1.00=0.20 9.00=0.70", "render: step envelopes get one point at the cut")

-- render: a take that never moved the parameter puts it back to the base value.
out = envelopes.render(
  { { from = 1, to = 8, auto = s1 }, { from = 9, to = 16, auto = {} } },
  16,
  { ["2:1"] = 0.4 }
)
t.eq(text(out["2:1"]), "1.00=0.20 9.00=0.40", "render: base value for a take without the envelope")
out = envelopes.render({ { from = 1, to = 8, auto = s1 }, { from = 9, to = 16, auto = {} } }, 16)
t.eq(text(out["2:1"]), "1.00=0.20", "render: no base value, no point")
t.eq(next(envelopes.render({}, 16)), nil, "render: no segments, no envelopes")

t.done()
