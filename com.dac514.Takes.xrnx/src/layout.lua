--[[
  Pure Lua (no renoise.*). Geometry of the lanes view.

  Time runs downward: one row of the view is one timeline row. Lanes are
  columns. Lane 0 is the comp, lanes 1..n are takes. Each lane has a "notes"
  strip and a "moves" strip, and each strip has a thin colour bar on its left
  that shows which take the comp uses there.

  All sizes are in view units. The same numbers serve to draw and to find what
  is under the mouse.
]]

local M = {}

M.GUTTER_W = 34 -- line numbers
M.HEADER_H = 30 -- lane titles and strip titles
M.CELL_W = 20 -- one note column: three glyphs and a gap
M.BAR_W = 3 -- colour bar of a strip
M.MOVES_W = 30 -- curve area of the moves strip
M.LANE_GAP = 6
M.COMP_GAP = 6 -- extra space after the comp lane
---Zoom levels. Each one divides the usual view height, so no band is left over.
M.ROW_HEIGHTS = { 12, 10, 8, 6, 4, 3, 2 }
M.TEXT_ROW_H = 8 -- rows at least this high always show text

---@class LayoutOptions
---@field total integer Number of timeline rows.
---@field lanes integer Number of take lanes that are shown. Ignored when `width` is set.
---@field note_cols integer Note columns shown in each lane.
---@field row_h number Height of a row. It may have a fraction.
---@field view_h integer Height available for rows.
---@field scroll integer First visible row.
---@field width integer? A fixed width. The view then shows as many lanes as fit, and the lanes share the space that is left.

---@class Layout : LayoutOptions
---@field notes_w integer Width of a notes strip.
---@field moves_w integer Width of a moves strip.
---@field lane_w integer
---@field visible integer Number of visible rows.
---@field width integer
---@field height integer

---Row height for a zoom level. Rows never get so small that the loop does not
---fill the view: a short loop gets taller rows instead of an empty band.
---@param level integer Index into `M.ROW_HEIGHTS`.
---@param total integer Number of timeline rows.
---@param view_h integer
---@return number
function M.row_height(level, total, view_h)
  local h = M.ROW_HEIGHTS[math.max(1, math.min(level, #M.ROW_HEIGHTS))]
  return math.max(h, view_h / total)
end

---@param opts LayoutOptions
---@return Layout
function M.new(opts)
  local note_cols = math.max(1, opts.note_cols)
  local notes_w = M.BAR_W + 3 + note_cols * M.CELL_W
  local moves_w = M.BAR_W + 2 + M.MOVES_W
  local lane_w = notes_w + 2 + moves_w
  local lanes = opts.lanes
  local width = M.GUTTER_W + M.COMP_GAP + (lanes + 1) * (lane_w + M.LANE_GAP)
  local fixed = opts.width
  if fixed then
    -- As many lanes as fit (the comp and at least one take). What is left
    -- over makes every moves strip a little wider.
    local room = fixed - M.GUTTER_W - M.COMP_GAP
    local slots = math.max(2, math.floor(room / (lane_w + M.LANE_GAP)))
    local extra = math.max(0, math.floor((room - slots * (lane_w + M.LANE_GAP)) / slots))
    moves_w = moves_w + extra
    lane_w = lane_w + extra
    lanes = slots - 1
    width = fixed
  end
  local visible = math.max(1, math.min(opts.total, math.floor(opts.view_h / opts.row_h + 0.001)))
  ---@type Layout
  local L = {
    total = opts.total,
    lanes = lanes,
    note_cols = note_cols,
    row_h = opts.row_h,
    view_h = opts.view_h,
    scroll = 1,
    notes_w = notes_w,
    moves_w = moves_w,
    lane_w = lane_w,
    visible = visible,
    width = width,
    height = M.HEADER_H + visible * opts.row_h,
  }
  L.scroll = M.clamp_scroll(L, opts.scroll)
  return L
end

---@param L Layout
---@param scroll integer
---@return integer
function M.clamp_scroll(L, scroll)
  return math.max(1, math.min(scroll, L.total - L.visible + 1))
end

---Left edge of a lane.
---@param L Layout
---@param lane integer 0 for the comp.
---@return integer
function M.lane_x(L, lane)
  local x = M.GUTTER_W + lane * (L.lane_w + M.LANE_GAP)
  if lane > 0 then
    x = x + M.COMP_GAP
  end
  return x
end

---Left edge and width of a strip.
---@param L Layout
---@param lane integer
---@param strip Layer
---@return integer x, integer w
function M.strip(L, lane, strip)
  local x = M.lane_x(L, lane)
  if strip == "notes" then
    return x, L.notes_w
  end
  return x + L.notes_w + 2, L.moves_w
end

---Top edge of a row, or nil when the row is not visible.
---@param L Layout
---@param row integer
---@return number?
function M.row_y(L, row)
  if row < L.scroll or row >= L.scroll + L.visible then
    return nil
  end
  return M.HEADER_H + (row - L.scroll) * L.row_h
end

---@class LayoutHit
---@field area "header"|"body"|"gutter"|"none"
---@field lane integer? 0 for the comp.
---@field strip Layer?
---@field row integer? Body and gutter only.

---What is at a point of the view.
---@param L Layout
---@param x number
---@param y number
---@return LayoutHit
function M.hit(L, x, y)
  local row = nil
  if y >= M.HEADER_H and y < L.height then
    row = L.scroll + math.floor((y - M.HEADER_H) / L.row_h)
    if row > L.total then
      row = nil
    end
  end
  if x >= 0 and x < M.GUTTER_W then
    return { area = row and "gutter" or "none", row = row }
  end
  for lane = 0, L.lanes do
    local lx = M.lane_x(L, lane)
    if x >= lx and x < lx + L.lane_w then
      local mx = M.strip(L, lane, "moves")
      local strip = x >= mx - 1 and "moves" or "notes"
      if y >= 0 and y < M.HEADER_H then
        return { area = "header", lane = lane, strip = strip }
      end
      if row then
        return { area = "body", lane = lane, strip = strip, row = row }
      end
    end
  end
  return { area = "none", row = row }
end

---The block of rows around a row that a swipe takes: one beat, or one line.
---Beats are counted from the start of each pattern.
---@param tl Timeline
---@param row integer
---@param unit integer Lines in a block (the lines per beat), or 1.
---@return integer from, integer to
function M.snap(tl, row, unit)
  row = math.max(1, math.min(row, tl.total))
  if unit <= 1 then
    return row, row
  end
  for _, slot in ipairs(tl.slots) do
    if row < slot.first + slot.lines then
      local line0 = row - slot.first
      local from0 = math.floor(line0 / unit) * unit
      local to0 = math.min(from0 + unit - 1, slot.lines - 1)
      return slot.first + from0, slot.first + to0
    end
  end
  return row, row
end

---Scroll position that makes a row visible, with the least movement.
---@param L Layout
---@param row integer
---@return integer scroll
function M.reveal(L, row)
  if row < L.scroll then
    return M.clamp_scroll(L, row)
  end
  if row >= L.scroll + L.visible then
    return M.clamp_scroll(L, row - L.visible + 1)
  end
  return L.scroll
end

---Scroll position for a playhead that leaves the window: turn the page.
---@param L Layout
---@param row integer
---@return integer scroll
function M.follow(L, row)
  if row >= L.scroll and row < L.scroll + L.visible then
    return L.scroll
  end
  return M.clamp_scroll(L, math.floor((row - 1) / L.visible) * L.visible + 1)
end

return M
