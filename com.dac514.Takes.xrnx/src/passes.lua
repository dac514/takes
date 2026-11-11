--[[
  Pure Lua (no renoise.*). Decides when the capture reads and clears each chunk
  of the loop, and when a pass is complete.

  Renoise records into the pattern while the loop plays. A chunk is read and
  cleared only after the playhead has left it by `guard` rows. So the chunk
  that the playhead enters next is always clean before it plays again, and a
  note that Renoise writes a little late still lands in the right pass.

  The state machine only sees the playhead row. It keeps an absolute position
  that never decreases, so a slow timer or a skipped row cannot confuse it.
]]

local M = {}

---@class PassAction
---@field kind "harvest"|"close"
---@field pass integer Pass number, starting at 0.
---@field chunk integer? Chunk index (harvest only).
---@field from integer? First row (harvest only).
---@field to integer? Last row (harvest only).
---@field overlapped boolean? The playhead entered the chunk again before the harvest (harvest only).
---@field complete boolean? The playhead reached the end of the pass (close only).

---@class PassState
---@field total integer
---@field chunks { from: integer, to: integer }[]
---@field guard integer
---@field abs integer Absolute playhead position: pass * total + row.
---@field last_row integer
---@field next_pass integer
---@field next_chunk integer
---@field open_pass integer? A pass that has harvested chunks and is not closed yet.

---@param total integer Number of rows of the loop.
---@param chunks { from: integer, to: integer }[]
---@param guard integer Rows that the playhead must be past a chunk before the harvest.
---@param start_row integer Playhead row when recording starts.
---@return PassState
function M.new(total, chunks, guard, start_row)
  assert(total >= 1 and #chunks >= 1, "bad loop")
  return {
    total = total,
    chunks = chunks,
    guard = guard,
    abs = start_row,
    last_row = start_row,
    next_pass = 0,
    next_chunk = 1,
  }
end

---@param state PassState
---@param actions PassAction[]
local function emit_next(state, actions)
  local c = state.chunks[state.next_chunk]
  local pass = state.next_pass
  local reentered = state.abs >= (pass + 1) * state.total + c.from
  actions[#actions + 1] = {
    kind = "harvest",
    pass = pass,
    chunk = state.next_chunk,
    from = c.from,
    to = c.to,
    overlapped = reentered,
  }
  if state.next_chunk == #state.chunks then
    actions[#actions + 1] =
      { kind = "close", pass = pass, complete = state.abs > (pass + 1) * state.total }
    state.open_pass = nil
    state.next_pass = pass + 1
    state.next_chunk = 1
  else
    state.open_pass = pass
    state.next_chunk = state.next_chunk + 1
  end
end

---Feed the current playhead row. Returns the actions that are due, in order.
---@param state PassState
---@param row integer
---@return PassAction[]
function M.step(state, row)
  local actions = {}
  local d = (row - state.last_row) % state.total
  state.abs = state.abs + d
  state.last_row = row
  while true do
    local c = state.chunks[state.next_chunk]
    local end_abs = state.next_pass * state.total + c.to
    if state.abs < end_abs + state.guard then
      break
    end
    emit_next(state, actions)
  end
  return actions
end

---Recording stopped. Returns the harvests for every chunk that the playhead has
---reached, and closes the passes they belong to.
---@param state PassState
---@return PassAction[]
function M.finish(state)
  local actions = {}
  while true do
    local c = state.chunks[state.next_chunk]
    local start_abs = state.next_pass * state.total + c.from
    if start_abs > state.abs then
      break
    end
    emit_next(state, actions)
  end
  if state.open_pass then
    actions[#actions + 1] = { kind = "close", pass = state.open_pass, complete = false }
    state.open_pass = nil
  end
  return actions
end

---Number of the pass that the playhead is in.
---@param state PassState
---@return integer
function M.current_pass(state)
  return math.floor((state.abs - 1) / state.total)
end

return M
