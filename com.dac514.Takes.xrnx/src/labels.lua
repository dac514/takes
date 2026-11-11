--[[
  Pure Lua (no renoise.*): the text that the view shows for pattern data.
  Kept apart from the view so that it can be unit-tested with `just test`.
]]

local M = {}

local NAMES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }

---Name of a note value as the pattern editor shows it.
---@param value integer 0-119 is a note, 120 is a note-off, 121 is empty.
---@return string
function M.note(value)
  if value == 120 then
    return "OFF"
  end
  if value < 0 or value > 119 then
    return "---"
  end
  return NAMES[value % 12 + 1] .. math.floor(value / 12)
end

---@param value integer
---@param empty integer The value that means "nothing here".
---@return string
local function byte(value, empty)
  if value == empty then
    return ".."
  end
  return ("%02X"):format(value)
end

---One note column as text: note, instrument, volume, panning, delay.
---@param cell integer[] { note, instrument, volume, panning, delay, fx number, fx amount }
---@return string
function M.note_cell(cell)
  local text = ("%s %s %s %s %s"):format(
    M.note(cell[1]),
    byte(cell[2], 255),
    byte(cell[3], 255),
    byte(cell[4], 255),
    byte(cell[5], 0)
  )
  if cell[6] ~= 0 or cell[7] ~= 0 then
    text = text .. (" %02X%02X"):format(cell[6] % 256, cell[7])
  end
  return text
end

---Hexadecimal line number as the pattern editor shows it (line 1 is "00").
---@param line integer Line number from 1.
---@return string
function M.line(line)
  return ("%02X"):format(line - 1)
end

---Short name of a lane.
---@param take_id integer? nil for the comp.
---@return string
function M.lane(take_id)
  if not take_id then
    return "COMP"
  end
  return ("TAKE %d"):format(take_id)
end

---Text for the readout line under the lanes.
---@param info { row: integer, line: integer, lane: string, notes: integer[][]?, notes_from: integer?, moves: string[]?, moves_from: integer? }
---@return string
function M.readout(info)
  local parts = { ("Line %s"):format(M.line(info.line)), info.lane }
  local cells = {}
  for _, cell in ipairs(info.notes or {}) do
    cells[#cells + 1] = M.note_cell(cell)
  end
  local from = info.notes_from and (" (take %d)"):format(info.notes_from) or ""
  parts[#parts + 1] = "notes" .. from .. ": " .. (#cells > 0 and table.concat(cells, " | ") or "-")
  from = info.moves_from and (" (take %d)"):format(info.moves_from) or ""
  local moves = info.moves or {}
  parts[#parts + 1] = "moves" .. from .. ": " .. (#moves > 0 and table.concat(moves, ", ") or "-")
  return table.concat(parts, "    ")
end

return M
