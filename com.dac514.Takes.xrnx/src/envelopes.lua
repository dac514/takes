--[[
  Pure Lua (no renoise.*). Automation envelopes over the timeline.

  An envelope belongs to one device parameter of the armed track:
    { device = index, param = index, playmode = 1|2|3, points = { { time, value, scaling }, ... } }
  `time` is a timeline row and may have a fraction: 5.5 is the middle of row 5.
  `value` is 0..1. Points are sorted by time. The key of an envelope in a
  content table is "device:param".

  Renoise draws a curve between points. When the comp changes take, the tool
  adds points on both sides of the cut, so each side keeps its own shape.
]]

local M = {}

M.PLAYMODE_POINTS = 1
M.PLAYMODE_LINES = 2
M.PLAYMODE_CURVES = 3

---Smallest step in time that Renoise keeps for most parameters.
M.TIME_QUANTUM = 1 / 256

---@class Envelope
---@field device integer
---@field param integer
---@field playmode integer
---@field points number[][] Each point is { time, value, scaling }.
---@field name string? Name of the device when the envelope was recorded. A different device at the same index is not written to.

---@param device integer
---@param param integer
---@return string
function M.key(device, param)
  return device .. ":" .. param
end

---@param env Envelope
---@return Envelope
local function shell(env)
  return {
    device = env.device,
    param = env.param,
    playmode = env.playmode,
    name = env.name,
    points = {},
  }
end

---@param points number[][]
local function sort_points(points)
  table.sort(points, function(a, b)
    return a[1] < b[1]
  end)
end

---Replace the points of `dst` inside the rows `from..to` with those of `src`.
---Envelopes that end with no point are removed.
---@param dst table<string, Envelope>
---@param src table<string, Envelope>
---@param from integer
---@param to integer
function M.copy_range(dst, src, from, to)
  local lo, hi = from, to + 1
  for key, env in pairs(dst) do
    local kept = {}
    for _, p in ipairs(env.points) do
      if p[1] < lo or p[1] >= hi then
        kept[#kept + 1] = p
      end
    end
    env.points = kept
    if #kept == 0 and not src[key] then
      dst[key] = nil
    end
  end
  for key, env in pairs(src) do
    local out = dst[key]
    for _, p in ipairs(env.points) do
      if p[1] >= lo and p[1] < hi then
        if not out then
          out = shell(env)
          dst[key] = out
        end
        out.points[#out.points + 1] = { p[1], p[2], p[3] or 0 }
      end
    end
    if out then
      if #out.points == 0 then
        dst[key] = nil
      else
        sort_points(out.points)
      end
    end
  end
end

---Compare two point lists. Times and values may differ by a rounding step.
---@param a number[][]
---@param b number[][]
---@return boolean
function M.same_points(a, b)
  if #a ~= #b then
    return false
  end
  for i, p in ipairs(a) do
    local q = b[i]
    if math.abs(p[1] - q[1]) > M.TIME_QUANTUM or math.abs(p[2] - q[2]) > 0.001 then
      return false
    end
  end
  return true
end

---Compare two envelope tables. Times and values may differ by a rounding step.
---@param a table<string, Envelope>
---@param b table<string, Envelope>
---@return boolean
function M.equal(a, b)
  for key, ea in pairs(a) do
    local eb = b[key]
    if not eb or not M.same_points(ea.points, eb.points) then
      return false
    end
  end
  for key in pairs(b) do
    if not a[key] then
      return false
    end
  end
  return true
end

---Value of the envelope at a time, or nil before its first point.
---"Curves" is treated as "Lines".
---@param env Envelope
---@param time number
---@return number?
function M.value_at(env, time)
  local before, after
  for _, p in ipairs(env.points) do
    if p[1] <= time then
      before = p
    else
      after = p
      break
    end
  end
  if not before then
    return nil
  end
  if env.playmode == M.PLAYMODE_POINTS or not after then
    return before[2]
  end
  local span = after[1] - before[1]
  if span <= 0 then
    return before[2]
  end
  return before[2] + (after[2] - before[2]) * (time - before[1]) / span
end

---Build the envelopes of a comp.
---@param moves { from: integer, to: integer, auto: table<string, Envelope> }[] Segments of the moves layer, sorted, each with the envelopes of its take.
---@param total integer
---@param base table<string, number>? Value of each parameter before any take moved it.
---@return table<string, Envelope>
function M.render(moves, total, base)
  local out = {}
  local keys = {}
  for _, seg in ipairs(moves) do
    for key, env in pairs(seg.auto) do
      if not keys[key] then
        keys[key] = env
      end
    end
  end
  for key, first_env in pairs(keys) do
    local res = shell(first_env)
    for _, seg in ipairs(moves) do
      local lo = seg.from
      local hi = math.min(seg.to, total) + 1
      local env = seg.auto[key]
      if env and #env.points > 0 then
        local has_start, last_time = false, nil
        for _, p in ipairs(env.points) do
          if p[1] >= lo and p[1] < hi then
            if p[1] == lo then
              has_start = true
            end
            res.points[#res.points + 1] = { p[1], p[2], p[3] or 0 }
            last_time = p[1]
          end
        end
        -- Cut at the start: keep the value that the take had at this row.
        if not has_start then
          local v = M.value_at(env, lo)
          if v == nil and base then
            v = base[key]
          end
          if v ~= nil then
            res.points[#res.points + 1] = { lo, v, 0 }
          end
        end
        -- Cut at the end: a line that continues past the cut must stop here.
        local end_time = hi - M.TIME_QUANTUM
        local continues = env.points[#env.points][1] >= hi
        if continues and env.playmode ~= M.PLAYMODE_POINTS and last_time ~= end_time then
          local v = M.value_at(env, end_time)
          if v ~= nil then
            res.points[#res.points + 1] = { end_time, v, 0 }
          end
        end
      elseif base and base[key] ~= nil then
        -- This take never moved the parameter: put it back where it was.
        res.points[#res.points + 1] = { lo, base[key], 0 }
      end
    end
    if #res.points > 0 then
      sort_points(res.points)
      out[key] = res
    end
  end
  return out
end

return M
