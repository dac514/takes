--[[
  Pure Lua (no renoise.*). The data model of takes and of the comp.

  Content is what one track holds over the timeline:
    notes[row][col] = { note, instrument, volume, panning, delay, fx number, fx amount }
    fx[row][col]    = { number, amount }
    auto[key]       = an envelope (see src/envelopes.lua)
  Only cells that are not empty are stored.

  A take is the content of one recording pass. The comp says, for each layer,
  which take each row comes from. The "notes" layer is the note columns. The
  "moves" layer is the effect columns and the automation.
]]

local envelopes = require "src.envelopes"

local M = {}

M.NOTE_OFF = 120
M.EMPTY_NOTE = 121
M.EMPTY_BYTE = 255

---@alias Layer "notes"|"moves"

---@class Content
---@field notes table<integer, table<integer, integer[]>>
---@field fx table<integer, table<integer, integer[]>>
---@field auto table<string, Envelope>

---@class Take
---@field id integer
---@field rows integer Number of timeline rows when the take was recorded.
---@field content Content
---@field overlapped boolean? The timer stalled, so two passes may be merged in this take.

---@class Segment
---@field from integer First row.
---@field to integer Last row.
---@field take integer Take id.

---@class Comp
---@field notes Segment[]
---@field moves Segment[]

---@return Content
function M.new_content()
  return { notes = {}, fx = {}, auto = {} }
end

---@return Comp
function M.new_comp()
  return { notes = {}, moves = {} }
end

---@param content Content
---@return boolean
function M.is_empty(content)
  return next(content.notes) == nil and next(content.fx) == nil and next(content.auto) == nil
end

---@param cell integer[]
---@return integer[]
local function copy_cell(cell)
  local out = {}
  for i = 1, #cell do
    out[i] = cell[i]
  end
  return out
end

---@param dst table<integer, table<integer, integer[]>>
---@param src table<integer, table<integer, integer[]>>
---@param from integer
---@param to integer
local function copy_grid(dst, src, from, to)
  for row = from, to do
    local cols = src[row]
    if cols then
      local out = {}
      for col, cell in pairs(cols) do
        out[col] = copy_cell(cell)
      end
      dst[row] = out
    else
      dst[row] = nil
    end
  end
end

---Replace the rows `from..to` of `dst` with those of `src`.
---@param dst Content
---@param src Content
---@param from integer
---@param to integer
---@param layer Layer? Both layers when nil.
function M.copy_rows(dst, src, from, to, layer)
  if layer == nil or layer == "notes" then
    copy_grid(dst.notes, src.notes, from, to)
  end
  if layer == nil or layer == "moves" then
    copy_grid(dst.fx, src.fx, from, to)
    envelopes.copy_range(dst.auto, src.auto, from, to)
  end
end

---@param a table?
---@param b table?
---@return boolean
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---@param a Content
---@param b Content
---@param layer Layer? Both layers when nil.
---@return boolean
function M.equal(a, b, layer)
  if (layer == nil or layer == "notes") and not deep_equal(a.notes, b.notes) then
    return false
  end
  if layer == nil or layer == "moves" then
    if not deep_equal(a.fx, b.fx) or not envelopes.equal(a.auto, b.auto) then
      return false
    end
  end
  return true
end

---Number of note events (notes, not note-offs) in the content.
---@param content Content
---@return integer
function M.count_notes(content)
  local n = 0
  for _, cols in pairs(content.notes) do
    for _, cell in pairs(cols) do
      if cell[1] < M.NOTE_OFF then
        n = n + 1
      end
    end
  end
  return n
end

---True when the content holds more than note-offs: a note, a value in a
---volume, panning or delay column, or a parameter move.
---@param content Content
---@return boolean
function M.has_events(content)
  if next(content.fx) ~= nil or next(content.auto) ~= nil then
    return true
  end
  for _, cols in pairs(content.notes) do
    for _, cell in pairs(cols) do
      if cell[1] ~= M.NOTE_OFF then
        return true
      end
    end
  end
  return false
end

---Number of rows that hold a parameter move, in effect columns or automation.
---@param content Content
---@return integer
function M.count_moves(content)
  local n = 0
  for _ in pairs(content.fx) do
    n = n + 1
  end
  for _, env in pairs(content.auto) do
    n = n + #env.points
  end
  return n
end

---Highest note column and effect column that the content uses.
---@param content Content
---@return integer note_columns, integer effect_columns
function M.columns(content)
  local nc, ec = 0, 0
  for _, cols in pairs(content.notes) do
    for col in pairs(cols) do
      nc = math.max(nc, col)
    end
  end
  for _, cols in pairs(content.fx) do
    for col in pairs(cols) do
      ec = math.max(ec, col)
    end
  end
  return nc, ec
end

-- Segments -------------------------------------------------------------------

---Give the rows `from..to` to a take. Returns a new sorted list without
---overlaps. A nil take removes the rows from the comp.
---@param segments Segment[]
---@param from integer
---@param to integer
---@param take integer?
---@return Segment[]
function M.assign(segments, from, to, take)
  if from > to then
    from, to = to, from
  end
  local out = {}
  for _, s in ipairs(segments) do
    if s.to < from or s.from > to then
      out[#out + 1] = { from = s.from, to = s.to, take = s.take }
    else
      if s.from < from then
        out[#out + 1] = { from = s.from, to = from - 1, take = s.take }
      end
      if s.to > to then
        out[#out + 1] = { from = to + 1, to = s.to, take = s.take }
      end
    end
  end
  if take then
    out[#out + 1] = { from = from, to = to, take = take }
  end
  table.sort(out, function(a, b)
    return a.from < b.from
  end)
  local merged = {}
  for _, s in ipairs(out) do
    local last = merged[#merged]
    if last and last.take == s.take and last.to + 1 == s.from then
      last.to = s.to
    else
      merged[#merged + 1] = s
    end
  end
  return merged
end

---@param segments Segment[]
---@param row integer
---@return integer? take_id
function M.take_at(segments, row)
  for _, s in ipairs(segments) do
    if row >= s.from and row <= s.to then
      return s.take
    end
  end
  return nil
end

---Remove a take from a segment list.
---@param segments Segment[]
---@param take integer
---@return Segment[]
function M.without_take(segments, take)
  local out = {}
  for _, s in ipairs(segments) do
    if s.take ~= take then
      out[#out + 1] = { from = s.from, to = s.to, take = s.take }
    end
  end
  return out
end

-- Rendering ------------------------------------------------------------------

---Add a note-off where a change of take would leave a note sounding.
---A column is "sounding" when its last event is a note. At the first row of a
---new segment, a sounding column without an event of its own gets a note-off.
---@param content Content
---@param segments Segment[]
---@param total integer
---@return integer healed Number of note-offs added.
function M.heal(content, segments, total)
  local healed = 0
  local max_col = M.columns(content)
  if max_col == 0 then
    return 0
  end
  local owner = {}
  for _, s in ipairs(segments) do
    for row = math.max(s.from, 1), math.min(s.to, total) do
      owner[row] = s.take
    end
  end
  local sounding = {}
  local function cut(row)
    local cols = content.notes[row]
    for col = 1, max_col do
      if sounding[col] and not (cols and cols[col]) then
        if not cols then
          cols = {}
          content.notes[row] = cols
        end
        cols[col] = { M.NOTE_OFF, M.EMPTY_BYTE, M.EMPTY_BYTE, M.EMPTY_BYTE, 0, 0, 0 }
        healed = healed + 1
      end
    end
  end
  for row = 1, total do
    if row > 1 and owner[row] ~= owner[row - 1] then
      cut(row)
    end
    local cols = content.notes[row]
    if cols then
      for col, cell in pairs(cols) do
        if cell[1] < M.NOTE_OFF then
          sounding[col] = true
        elseif cell[1] == M.NOTE_OFF then
          sounding[col] = false
        end
      end
    end
  end
  if total > 1 and owner[1] ~= owner[total] then
    cut(1)
  end
  return healed
end

---Build the track content that the comp describes.
---@param takes table<integer, Take> Takes by id.
---@param comp Comp
---@param total integer Number of timeline rows.
---@param base table<string, number>? Value of each automated parameter before any take moved it.
---@return Content content, integer healed
function M.render(takes, comp, total, base)
  local content = M.new_content()
  for _, s in ipairs(comp.notes) do
    local take = takes[s.take]
    if take then
      M.copy_rows(content, take.content, s.from, math.min(s.to, total), "notes")
    end
  end
  local moves = {}
  for _, s in ipairs(comp.moves) do
    local take = takes[s.take]
    if take then
      copy_grid(content.fx, take.content.fx, s.from, math.min(s.to, total))
      moves[#moves + 1] = { from = s.from, to = math.min(s.to, total), auto = take.content.auto }
    end
  end
  content.auto = envelopes.render(moves, total, base)
  local healed = M.heal(content, comp.notes, total)
  return content, healed
end

---A parameter stays where the last envelope left it. So when any take of the
---session moves a parameter and `content` does not, put one point at row 1
---that sets the parameter back to its value from before the takes.
---@param content Content
---@param all Take[] Every take of the session.
---@param base table<string, number>?
---@return integer added
function M.add_base_points(content, all, base)
  local added = 0
  if not base then
    return 0
  end
  for _, take in ipairs(all) do
    for key, env in pairs(take.content.auto) do
      if not content.auto[key] and base[key] ~= nil then
        content.auto[key] = {
          device = env.device,
          param = env.param,
          name = env.name,
          playmode = envelopes.PLAYMODE_POINTS,
          points = { { 1, base[key], 0 } },
        }
        added = added + 1
      end
    end
  end
  return added
end

---Content of one whole take, as the track should hold it for an audition.
---@param take Take
---@param total integer
---@return Content
function M.solo(take, total)
  local content = M.new_content()
  M.copy_rows(content, take.content, 1, total)
  return content
end

---A note held across the loop end gets its note-off in the next pass. Copy
---such a leading note-off into the earlier take, so that the earlier take
---does not hang when it loops alone.
---@param prev Take The take of the pass before.
---@param cur Take
---@return integer adopted
function M.adopt_orphan_offs(prev, cur)
  local adopted = 0
  local max_col = M.columns(prev.content)
  for col = 1, max_col do
    local last_is_note = false
    for row = prev.rows, 1, -1 do
      local cols = prev.content.notes[row]
      if cols and cols[col] then
        last_is_note = cols[col][1] < M.NOTE_OFF
        break
      end
    end
    if last_is_note then
      for row = 1, cur.rows do
        local cols = cur.content.notes[row]
        local cell = cols and cols[col]
        if cell then
          local pcols = prev.content.notes[row]
          if cell[1] == M.NOTE_OFF and not (pcols and pcols[col]) then
            if not pcols then
              pcols = {}
              prev.content.notes[row] = pcols
            end
            pcols[col] = copy_cell(cell)
            adopted = adopted + 1
          end
          break
        end
      end
    end
  end
  return adopted
end

return M
