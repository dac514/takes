--[[
  Pure Lua (no renoise.*). The looped part of the song as one row axis.

  A loop is a list of sequence slots. Each slot plays one pattern with its own
  number of lines. The timeline joins them: row 1 is line 1 of the first slot,
  and the last row is the last line of the last slot. Takes, the comp and the
  view all work in timeline rows.
]]

local M = {}

---@class TimelineSlot
---@field seq integer Sequence position of the slot.
---@field pattern integer Pattern index that the slot plays.
---@field lines integer Number of lines of that pattern.
---@field first integer First timeline row of the slot (set by `new`).

---@class Timeline
---@field slots TimelineSlot[]
---@field total integer Number of rows.

---@class TimelineSpan
---@field slot integer Index into `timeline.slots`.
---@field from_line integer
---@field to_line integer
---@field first_row integer Timeline row of `from_line`.

---@class TimelineChunk
---@field from integer First row.
---@field to integer Last row.

---@param slots { seq: integer, pattern: integer, lines: integer }[]
---@return Timeline
function M.new(slots)
  assert(#slots > 0, "a timeline needs at least one slot")
  local out, row = {}, 1
  for i, s in ipairs(slots) do
    assert(s.lines >= 1, "a slot needs at least one line")
    out[i] = { seq = s.seq, pattern = s.pattern, lines = s.lines, first = row }
    row = row + s.lines
  end
  return { slots = out, total = row - 1 }
end

---Timeline row of a song position, or nil when the position is outside the loop.
---@param tl Timeline
---@param seq integer
---@param line integer
---@return integer?
function M.row_of(tl, seq, line)
  for _, s in ipairs(tl.slots) do
    if s.seq == seq then
      if line < 1 or line > s.lines then
        return nil
      end
      return s.first + line - 1
    end
  end
  return nil
end

---Slot index and line of a timeline row.
---@param tl Timeline
---@param row integer
---@return integer? slot_index, integer? line
function M.locate(tl, row)
  if row < 1 or row > tl.total then
    return nil, nil
  end
  for i, s in ipairs(tl.slots) do
    if row < s.first + s.lines then
      return i, row - s.first + 1
    end
  end
  return nil, nil
end

---Cut a row range into one span per slot.
---@param tl Timeline
---@param from_row integer
---@param to_row integer
---@return TimelineSpan[]
function M.spans(tl, from_row, to_row)
  local out = {}
  from_row = math.max(from_row, 1)
  to_row = math.min(to_row, tl.total)
  for i, s in ipairs(tl.slots) do
    local a = math.max(from_row, s.first)
    local b = math.min(to_row, s.first + s.lines - 1)
    if a <= b then
      out[#out + 1] =
        { slot = i, from_line = a - s.first + 1, to_line = b - s.first + 1, first_row = a }
    end
  end
  return out
end

---The parts of the loop that the capture reads and clears one after the other.
---A loop of several patterns gives one chunk per slot. A loop of one pattern
---gives two halves, so that one half is always far from the playhead.
---@param tl Timeline
---@return TimelineChunk[]
function M.chunks(tl)
  if #tl.slots == 1 then
    local half = math.floor(tl.total / 2)
    if half < 1 then
      return { { from = 1, to = tl.total } }
    end
    return { { from = 1, to = half }, { from = half + 1, to = tl.total } }
  end
  local out = {}
  for i, s in ipairs(tl.slots) do
    out[i] = { from = s.first, to = s.first + s.lines - 1 }
  end
  return out
end

---True when two timelines describe the same slots.
---@param a Timeline
---@param b Timeline
---@return boolean
function M.same(a, b)
  if #a.slots ~= #b.slots then
    return false
  end
  for i, s in ipairs(a.slots) do
    local o = b.slots[i]
    if s.seq ~= o.seq or s.pattern ~= o.pattern or s.lines ~= o.lines then
      return false
    end
  end
  return true
end

return M
