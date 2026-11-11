--[[
  The lanes view: a canvas dialog that shows the comp and the takes as columns,
  with time running downward like the pattern editor.

  Three views are stacked:
  * the content canvas (lanes, notes, curves): redrawn only when data changes;
  * the overlay canvas (cursor, selection, swipe): redrawn when the cursor moves;
  * the playhead: a thin canvas that is moved, never redrawn.

  The canvas has no text function, so all text in it comes from the pixel font.
  Geometry and hit testing live in `src/layout.lua`, which is unit-tested.
]]

local envelopes = require "src.envelopes"
local font = require "src.pixelfont"
local labels = require "src.labels"
local layout = require "src.layout"
local takes = require "src.takes"

local M = {}

M.MAX_NOTE_COLS = 4
M.VIEW_H = 480
---The canvas keeps one size. It shows as many lanes as fit, and empty lanes
---stand for the takes to come. So the window never changes size.
M.CANVAS_W = 842
M.CANVAS_H = layout.HEADER_H + M.VIEW_H
M.SCROLL_W = 14
M.TICK_MS = 40

M.HELP = [[Takes: record several passes over a loop, then build the best version.

1. Loop a pattern, or a range of patterns in the sequencer.
2. Put the cursor in a track and press Arm.
3. Play with edit mode on and pattern follow on. Each pass of the loop becomes a take.
   Arm turns pattern follow on for you. The status line says what is missing.
   The pattern matrix shows the armed track in orange. While you record, its slots flash red.
4. Turn edit mode off. You hear the newest complete take.
5. Press Done to keep the result in the pattern. The takes stay in the song.

Mouse
- Swipe down a take lane: use those lines in the comp.
- Double-click a take lane: use the whole take.
- Click a take title: hear that take alone. Click again to hear the comp.
- Click the COMP title: hear the comp.
- Wheel: zoom in and out.
- Shift + wheel, or the wheel over the line numbers: scroll.
- The bar under the lanes, or Ctrl + wheel: move to earlier and later takes.
  "<5" in the top left corner means that five earlier takes are out of view.

Keys, when this window has the focus
- Up, Down: move the selection by one beat. With Ctrl: by one line.
- Shift + Up, Down: make the selection longer or shorter.
- Left, Right: move to another lane. At the edge, the next take comes into view.
- Enter: give the selected lines to the take under the cursor.
- 1 to 8: give the selected lines to that take lane.
- S: hear the take under the cursor. 0: hear the comp.
- Delete: remove the selected lines from the comp.

Each lane has two strips. "Notes" shows the note columns. "Moves" shows
parameter moves: effect commands and automation.]]

---Colours of the takes. Fixed, so that a take keeps its colour in every theme.
local PALETTE = {
  { 240, 128, 60 },
  { 70, 185, 125 },
  { 85, 155, 245 },
  { 225, 95, 150 },
  { 205, 185, 65 },
  { 155, 115, 235 },
  { 70, 200, 210 },
  { 235, 105, 75 },
  { 140, 205, 85 },
  { 240, 160, 205 },
  { 105, 125, 235 },
  { 190, 150, 105 },
}

---Named colours: { colour, alpha }. A colour is a theme colour name or RGB.
---@type table<string, { [1]: any, [2]: integer }>
local COLORS = {
  back = { "body_back", 255 },
  lane = { "pattern_default_back", 255 },
  beat = { "pattern_highlighted_back", 255 },
  text = { "pattern_default_font", 255 },
  text_dim = { "pattern_default_font", 135 },
  text_off = { "pattern_default_font", 85 },
  head = { "body_font", 255 },
  head_dim = { "body_font", 120 },
  head_faint = { "body_font", 50 },
  lane_empty = { "pattern_default_back", 190 },
  beat_empty = { "pattern_highlighted_back", 90 },
  rule = { "body_font", 60 },
  cursor = { "selected_button_back", 255 },
  select = { "selected_button_back", 55 },
  rec = { { 230, 60, 60 }, 255 },
}
for i, rgb in ipairs(PALETTE) do
  COLORS["t" .. i] = { rgb, 255 }
  COLORS["t" .. i .. "tint"] = { rgb, 60 }
  COLORS["t" .. i .. "soft"] = { rgb, 28 }
  COLORS["t" .. i .. "drag"] = { rgb, 120 }
end

---@param take_id integer
---@return string
local function take_color(take_id)
  return "t" .. ((take_id - 1) % #PALETTE + 1)
end

---Collects rectangles by colour, then fills each colour in one path.
---@param ctx renoise.Views.Canvas.Context
local function painter(ctx)
  local buckets, order = {}, {}
  ---@param color string
  local function rect(color, x, y, w, h)
    local b = buckets[color]
    if not b then
      b = {}
      buckets[color] = b
      order[#order + 1] = color
    end
    local n = #b
    b[n + 1], b[n + 2], b[n + 3], b[n + 4] = x, y, w, h
  end
  local function flush()
    for _, color in ipairs(order) do
      local b = buckets[color]
      local spec = COLORS[color]
      ctx.fill_color = spec[1]
      ctx.global_alpha = spec[2]
      ctx:begin_path()
      for i = 1, #b, 4 do
        ctx:rect(b[i], b[i + 1], b[i + 2], b[i + 3])
      end
      ctx:fill()
    end
    ctx.global_alpha = 255
    buckets, order = {}, {}
  end
  ---@param color string
  ---@param str string
  ---@param scale integer?
  local function text(color, str, x, y, scale)
    font.draw(str, math.floor(x), math.floor(y), function(rx, ry, rw, rh)
      rect(color, rx, ry, rw, rh)
    end, scale)
  end
  return rect, text, flush
end

---@class UiLane
---@field take Take? nil for the comp and for the recording lane.
---@field content Content
---@field kind "comp"|"take"|"rec"|"empty"
---@field color string? Colour name of the take.
---@field title string? Title of an empty lane: the take that will land there.

---@param app table The application module (`src/app.lua`).
---@return renoise.ViewBuilder vb, renoise.Views.View root, table handlers
function M.build(app)
  local vb = renoise.ViewBuilder()
  local session = app.session
  local scope = app.reg.scope()

  local state = {
    zoom = 1,
    scroll = 1,
    lane = 1, -- cursor lane: always a take lane (lane 0 is the comp)
    strip = "notes",
    from = 1, -- selected rows
    to = 1,
    anchor = 1,
    drag = nil, ---@type { lane: integer, strip: Layer, row: integer }?
    snap_beat = true,
    follow = true,
    dirty = true,
    tick = 0,
    hidden = 0, -- earlier takes that are out of view on the left
    hidden_after = 0, -- later takes that are out of view on the right
    first_take = nil, ---@type integer? index of the first take in view; nil shows the newest takes
    first_shown = 1,
    takes_room = 1, -- take lanes that fit in the view
    render_ms = 0, -- time of the last redraw of the content canvas
    take_lanes = 0, -- lanes that hold a take: the cursor stays inside them
  }
  ---@type { S: SessionState?, lanes: UiLane[], lpb: integer, comp: Content? }
  local model = { S = nil, lanes = {}, lpb = 4, comp = nil }
  ---@type Layout
  local L = layout.new {
    total = 64,
    lanes = 0,
    note_cols = 2,
    row_h = 12,
    view_h = M.VIEW_H,
    scroll = 1,
    width = M.CANVAS_W,
  }

  -- Model ----------------------------------------------------------------------

  local function rebuild()
    local song = renoise.song()
    local S = session.get()
    model.S = S
    model.lanes = {}
    model.lpb = song and song.transport.lpb or 4
    model.comp = session.comp_content()
    local note_cols = 2 -- two columns at least, so that the strip titles fit
    local live = S and S.rec and (session.live_content() or takes.new_content()) or nil
    if S then
      for _, take in ipairs(S.takes) do
        note_cols = math.max(note_cols, (takes.columns(take.content)))
      end
      if live then
        note_cols = math.max(note_cols, (takes.columns(live)))
      end
    end
    local total = S and S.tl.total or 64
    L = layout.new {
      total = total,
      lanes = 0,
      note_cols = math.min(note_cols, M.MAX_NOTE_COLS),
      row_h = layout.row_height(state.zoom, total, M.VIEW_H),
      view_h = M.VIEW_H,
      scroll = state.scroll,
      width = M.CANVAS_W,
    }
    state.hidden, state.take_lanes = 0, 0
    if S then
      local room = L.lanes - (live and 1 or 0) -- take lanes that fit
      local newest_first = math.max(1, #S.takes - room + 1)
      local first = newest_first
      if state.first_take and not live then
        first = math.max(1, math.min(state.first_take, newest_first))
      end
      if first >= newest_first then
        state.first_take = nil -- back at the newest takes: new takes scroll into view again
      end
      local last_shown = math.min(#S.takes, first + room - 1)
      state.first_shown, state.takes_room = first, room
      state.hidden = first - 1
      state.hidden_after = #S.takes - last_shown
      model.lanes[1] = { kind = "comp", content = model.comp or takes.new_content() }
      for i = first, last_shown do
        local take = S.takes[i]
        model.lanes[#model.lanes + 1] =
          { kind = "take", take = take, content = take.content, color = take_color(take.id) }
      end
      state.take_lanes = #model.lanes - 1
      if live then
        model.lanes[#model.lanes + 1] = { kind = "rec", content = live }
      end
      -- Empty lanes fill the rest of the view. Each one shows the take that will land there.
      local next_id = S.next_id + (live and 1 or 0)
      local nothing = takes.new_content()
      while #model.lanes < L.lanes + 1 do
        model.lanes[#model.lanes + 1] =
          { kind = "empty", content = nothing, title = labels.lane(next_id) }
        next_id = next_id + 1
      end
    end
    state.scroll = L.scroll
    state.lane = math.max(1, math.min(state.lane, state.take_lanes))
    state.from = math.max(1, math.min(state.from, L.total))
    state.to = math.max(1, math.min(state.to, L.total))
  end

  ---Pattern line of a timeline row, and true when the row starts a pattern.
  ---@param row integer
  ---@return integer line, boolean starts
  local function line_of(row)
    local S = model.S
    if S then
      for _, slot in ipairs(S.tl.slots) do
        if row < slot.first + slot.lines then
          return row - slot.first + 1, row == slot.first and #S.tl.slots > 1
        end
      end
    end
    return row, false
  end

  -- Drawing --------------------------------------------------------------------

  ---@param ctx renoise.Views.Canvas.Context
  local function render_content(ctx)
    local started_at = os.clock()
    local rect, text, flush = painter(ctx)
    local S = model.S
    local W, H = L.width, M.CANVAS_H
    rect("back", 0, 0, W, H)
    local rh = L.row_h
    local last = L.scroll + L.visible - 1
    local body_h = L.visible * rh

    if not S then
      flush()
      local lines = {
        "1  LOOP A PATTERN OR A SEQUENCE RANGE",
        "2  PUT THE CURSOR IN A TRACK",
        "3  PRESS ARM",
        "4  PLAY WITH EDIT MODE AND PATTERN FOLLOW ON",
        "   EACH PASS OF THE LOOP IS A TAKE",
        "5  SWIPE DOWN A TAKE TO USE ITS LINES",
        "6  CLICK A TAKE TITLE TO HEAR IT ALONE",
        "7  PRESS DONE TO KEEP THE RESULT",
      }
      local block_w = 0
      for _, line in ipairs(lines) do
        block_w = math.max(block_w, font.width(line))
      end
      local block_h = 14 * 2 + 16 + #lines * 16
      local x = (W - block_w) / 2
      local y = (H - block_h) / 2
      text("head", "TAKES", (W - font.width "TAKES" * 2) / 2, y, 2)
      rect("rule", x, y + 24, block_w, 1)
      for i, line in ipairs(lines) do
        text("head", line, x, y + 28 + i * 16)
      end
      flush()
      return
    end

    -- Lanes: background and beat rows. Empty lanes are only a faint panel.
    for lane = 0, L.lanes do
      local empty = model.lanes[lane + 1] == nil or model.lanes[lane + 1].kind == "empty"
      for _, strip in ipairs { "notes", "moves" } do
        local x, w = layout.strip(L, lane, strip)
        rect(empty and "lane_empty" or "lane", x, layout.HEADER_H, w, body_h)
      end
    end
    local filled = L.lanes
    while
      filled > 0 and (model.lanes[filled + 1] == nil or model.lanes[filled + 1].kind == "empty")
    do
      filled = filled - 1
    end
    for row = L.scroll, last do
      local line = line_of(row)
      if (line - 1) % model.lpb == 0 then
        local y = layout.HEADER_H + (row - L.scroll) * rh
        -- Empty lanes get the same rows, dimmed, so they read as lanes and not as a grey block.
        for lane = 0, L.lanes do
          for _, strip in ipairs { "notes", "moves" } do
            local x, w = layout.strip(L, lane, strip)
            rect(lane <= filled and "beat" or "beat_empty", x, y, w, rh)
          end
        end
      end
    end
    flush()

    -- Which take the comp uses: a tint and a solid bar in each strip.
    ---@param lane integer
    ---@param strip Layer
    ---@param seg Segment
    ---@param soft boolean
    local function mark(lane, strip, seg, soft)
      local a, b = math.max(seg.from, L.scroll), math.min(seg.to, last)
      if a > b then
        return
      end
      local x, w = layout.strip(L, lane, strip)
      local y = layout.HEADER_H + (a - L.scroll) * rh
      local h = (b - a + 1) * rh
      local color = take_color(seg.take)
      rect(color .. (soft and "soft" or "tint"), x, y, w, h)
      rect(color, x, y, layout.BAR_W, h)
    end
    for index, lane in ipairs(model.lanes) do
      for _, strip in ipairs { "notes", "moves" } do
        for _, seg in ipairs(S.comp[strip]) do
          if lane.kind == "comp" then
            mark(index - 1, strip, seg, true)
          elseif lane.kind == "take" and lane.take.id == seg.take then
            mark(index - 1, strip, seg, false)
          end
        end
      end
    end
    flush()

    -- Notes as tracker text. Small rows show text only where it has room.
    local need = math.ceil((font.HEIGHT + 1) / rh) -- rows that one text line covers
    for index, lane in ipairs(model.lanes) do
      local x0 = layout.strip(L, index - 1, "notes") + layout.BAR_W + 3
      local notes = lane.content.notes
      local used = lane.kind ~= "take" and {} or nil
      for row = L.scroll, last do
        local cols = notes[row]
        if cols then
          local y = layout.HEADER_H + (row - L.scroll) * rh
          local bright = used ~= nil or takes.take_at(S.comp.notes, row) == lane.take.id
          local overflow = false
          for col, cell in pairs(cols) do
            if col > L.note_cols then
              overflow = true
            else
              local x = x0 + (col - 1) * layout.CELL_W
              local is_off = cell[1] == takes.NOTE_OFF
              local color = is_off and "text_off" or (bright and "text" or "text_dim")
              local room = true
              if need > 1 then
                for r = row + 1, math.min(row + need - 1, last) do
                  if notes[r] and notes[r][col] then
                    room = false
                    break
                  end
                end
              end
              if room and row + need - 1 <= last then
                text(
                  color,
                  labels.note(cell[1]),
                  x,
                  y + math.max(0, math.floor((rh - font.HEIGHT) / 2))
                )
              else
                rect(color, x, y, is_off and 6 or 14, math.max(1, rh - 1))
              end
            end
          end
          if overflow then
            local x = x0 + L.note_cols * layout.CELL_W - 5
            rect("text_dim", x, y + math.floor(rh / 2), 3, 1)
          end
        end
      end
    end

    -- Gutter: line numbers.
    local step = 1
    if rh < layout.TEXT_ROW_H then
      step = model.lpb
      while step * rh < font.HEIGHT + 2 do
        step = step * 2
      end
    end
    for row = L.scroll, last do
      local line, starts = line_of(row)
      local y = layout.HEADER_H + (row - L.scroll) * rh
      if starts then
        rect("rule", 0, y, W, 1)
      end
      if (line - 1) % step == 0 and row + math.ceil(font.HEIGHT / rh) - 1 <= last then
        local beat = (line - 1) % model.lpb == 0
        local label = labels.line(line)
        if line > 256 then
          label = ("%03X"):format(line - 1)
        end
        text(
          beat and "head" or "head_dim",
          label,
          layout.GUTTER_W - 6 - font.width(label),
          y + math.max(0, math.floor((rh - font.HEIGHT) / 2))
        )
      end
    end
    flush()

    -- Moves: effect commands as blocks, envelopes as curves.
    for index, lane in ipairs(model.lanes) do
      local sx = layout.strip(L, index - 1, "moves") + layout.BAR_W + 2
      local color = lane.color or "text"
      for row = L.scroll, last do
        local cols = lane.content.fx[row]
        if cols then
          local _, cell = next(cols)
          if cell then
            local y = layout.HEADER_H + (row - L.scroll) * rh
            local x = sx + math.floor(cell[2] / 255 * (layout.MOVES_W - 3))
            rect(color, x, y, 3, math.max(1, rh - 1))
          end
        end
      end
    end
    flush()
    for index, lane in ipairs(model.lanes) do
      local sx = layout.strip(L, index - 1, "moves") + layout.BAR_W + 2
      local spec = COLORS[lane.color or "text"]
      for _, env in pairs(lane.content.auto) do
        ctx.stroke_color = spec[1]
        ctx.line_width = 1.5
        ctx:begin_path()
        local started = false
        local px, py, count = 0, 0, 0
        for i, p in ipairs(env.points) do
          local next_point = env.points[i + 1]
          local visible = p[1] >= L.scroll - 1 and p[1] <= last + 2
          local near = next_point and next_point[1] >= L.scroll - 1 and p[1] <= last + 2
          if visible or near then
            local x = sx + p[2] * (layout.MOVES_W - 2) + 1
            local y = layout.HEADER_H + (p[1] - L.scroll) * rh + rh / 2
            if not started then
              ctx:move_to(x, y)
              started = true
            else
              if env.playmode == envelopes.PLAYMODE_POINTS then
                ctx:line_to(px, y)
              end
              ctx:line_to(x, y)
            end
            px, py, count = x, y, count + 1
          end
        end
        if started then
          if count == 1 then
            ctx:line_to(px, py + 4) -- one point alone: a short mark
          end
          ctx:stroke()
        end
      end
    end

    -- Header, drawn last so that it covers curves that start above the window.
    rect("back", 0, 0, W, layout.HEADER_H)
    flush()
    for index, lane in ipairs(model.lanes) do
      local x = layout.lane_x(L, index - 1)
      local title, color = "COMP", "head"
      if lane.kind == "take" then
        title = labels.lane(lane.take.id)
        rect(lane.color, x, layout.HEADER_H - 4, L.lane_w, 3)
        if S.solo == lane.take.id then
          rect(lane.color .. "tint", x, 0, L.lane_w, layout.HEADER_H - 4)
          text("head", "SOLO", x + L.lane_w - font.width "SOLO" - 3, 4)
        elseif lane.take.overlapped then
          text("head_dim", "*", x + L.lane_w - 9, 4)
        end
      elseif lane.kind == "rec" then
        title, color = "REC", "rec"
        rect("rec", x, layout.HEADER_H - 4, L.lane_w, 3)
      elseif lane.kind == "empty" then
        title, color = lane.title or "", "head_dim"
        rect("head_faint", x, layout.HEADER_H - 4, L.lane_w, 3)
      else
        rect("head_dim", x, layout.HEADER_H - 4, L.lane_w, 3)
        if S.solo then
          color = "head_dim"
        end
      end
      local sub = lane.kind == "empty" and "head_faint" or "head_dim"
      text(color, title, x + 3, 4)
      text(sub, "NOTES", x + 3, 16)
      text(sub, "MOVES", (layout.strip(L, index - 1, "moves")) + 1, 16)
    end
    -- Takes out of view: "<5" means five earlier takes on the left, "2>" two later on the right.
    if state.hidden > 0 then
      text("head", ("<%d"):format(state.hidden), 3, 4)
    end
    if state.hidden_after > 0 then
      text("head", ("%d>"):format(state.hidden_after), 3, 16)
    end
    if state.take_lanes == 0 and not S.rec then
      -- No take yet: say what to do, centred over the empty lanes.
      local left = layout.lane_x(L, 1)
      local hint = {
        "NO TAKES YET",
        "",
        "PLAY WITH EDIT MODE AND PATTERN FOLLOW ON",
        "EACH PASS OF THE LOOP BECOMES A TAKE HERE",
      }
      for i, line in ipairs(hint) do
        text(
          i == 1 and "head" or "head_dim",
          line,
          left + (W - left - font.width(line)) / 2,
          layout.HEADER_H + body_h / 2 - 32 + i * 16
        )
      end
    end
    flush()
    state.render_ms = (os.clock() - started_at) * 1000
  end

  ---Rows that a swipe covers so far.
  ---@return integer from, integer to
  local function drag_rows()
    local d = state.drag
    if not d or not model.S then
      return state.from, state.to
    end
    local unit = state.snap_beat and model.lpb or 1
    local a1, a2 = layout.snap(model.S.tl, state.anchor, unit)
    local b1, b2 = layout.snap(model.S.tl, d.row, unit)
    return math.min(a1, b1), math.max(a2, b2)
  end

  ---@param ctx renoise.Views.Canvas.Context
  local function render_overlay(ctx)
    local S = model.S
    if not S then
      return
    end
    local rect, _, flush = painter(ctx)
    local from, to = state.from, state.to
    if state.drag then
      from, to = drag_rows()
    end
    local a, b = math.max(from, L.scroll), math.min(to, L.scroll + L.visible - 1)
    if a > b then
      return
    end
    local link = S.link
    ---@type Layer
    local strip = (link or state.strip ~= "moves") and "notes" or "moves"
    local x, w = layout.strip(L, state.lane, strip)
    if link then
      w = L.lane_w
    end
    local y = layout.HEADER_H + (a - L.scroll) * L.row_h
    local h = (b - a + 1) * L.row_h
    local lane = model.lanes[state.lane + 1]
    if not lane or lane.kind ~= "take" then
      return -- only takes can be selected
    end
    if state.drag then
      rect(lane.color .. "drag", x, y, w, h)
    else
      rect("select", x, y, w, h)
    end
    rect("cursor", x, y, w, 1)
    rect("cursor", x, y + h - 1, w, 1)
    rect("cursor", x, y, 1, h)
    rect("cursor", x + w - 1, y, 1, h)
    flush()
  end

  -- Views ----------------------------------------------------------------------

  local content = vb:canvas {
    id = "lanes",
    mode = "plain",
    width = M.CANVAS_W,
    height = M.CANVAS_H,
    render = app.safe(render_content),
  }
  local overlay = vb:canvas {
    id = "overlay",
    mode = "transparent",
    width = M.CANVAS_W,
    height = M.CANVAS_H,
    render = app.safe(render_overlay),
  }
  local playhead = vb:canvas {
    id = "playhead",
    mode = "plain",
    width = M.CANVAS_W,
    height = 2,
    visible = false,
    render = function(ctx)
      ctx.fill_color = "pattern_playposition_font"
      ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
    end,
  }
  local FULL_W = M.CANVAS_W + M.SCROLL_W
  -- A text view grows with its text and would widen the window. So every
  -- text in the bars is cut to a length that fits (see `fit`).
  local status = vb:text { id = "status", text = "", font = "bold", width = FULL_W - 16 }
  local hint = vb:text { id = "hint", text = "", width = FULL_W - 16 }
  local readout = vb:text { id = "readout", text = "", font = "mono", width = FULL_W - 16 }

  ---Cut a text so that it never makes its bar wider than the lanes.
  ---@param text string
  ---@param max integer Characters that fit.
  ---@return string
  local function fit(text, max)
    if #text <= max then
      return text
    end
    return text:sub(1, max - 3) .. "..."
  end
  local arm_button, scrollbar, link_box ---@type renoise.Views.Button, renoise.Views.ScrollBar, renoise.Views.CheckBox
  local follow_box ---@type renoise.Views.CheckBox

  ---The user scrolled by hand: stop following the playhead, and show that in the box.
  local function stop_follow()
    state.follow = false
    if follow_box and follow_box.value then
      follow_box.value = false
    end
  end
  local lane_bar ---@type renoise.Views.ScrollBar
  local updating = false

  local function update_readout()
    local S = model.S
    local lane = model.lanes[state.lane + 1]
    if not S or not lane or lane.kind ~= "take" then
      readout.text = ""
      return
    end
    local song = renoise.song()
    local row = state.from
    local cells = {}
    for col, cell in pairs(lane.content.notes[row] or {}) do
      cells[#cells + 1] = { col, cell }
    end
    table.sort(cells, function(a, b)
      return a[1] < b[1]
    end)
    local notes = {}
    for i, c in ipairs(cells) do
      notes[i] = c[2]
    end
    local moves = {}
    for _, cell in pairs(lane.content.fx[row] or {}) do
      moves[#moves + 1] = ("%02X%02X"):format(cell[1] % 256, cell[2])
    end
    for _, env in pairs(lane.content.auto) do
      local value = envelopes.value_at(env, row)
      if value then
        local name = "parameter"
        local track = song and S.track <= #song.tracks and song:track(S.track) or nil
        if track and env.device <= #track.devices then
          local device = track:device(env.device)
          if env.param <= #device.parameters then
            name = device:parameter(env.param).name
          end
        end
        moves[#moves + 1] = ("%s %.2f"):format(name, value)
      end
    end
    local title = lane.kind == "take" and labels.lane(lane.take.id)
      or (lane.kind == "rec" and "REC" or "COMP")
    local line = labels.readout {
      row = row,
      line = (line_of(row)),
      lane = title,
      notes = notes,
      notes_from = lane.kind == "comp" and takes.take_at(S.comp.notes, row) or nil,
      moves = moves,
      moves_from = lane.kind == "comp" and takes.take_at(S.comp.moves, row) or nil,
    }
    readout.text = fit(line, 118)
  end

  local last_status, last_hint, last_arm = nil, nil, nil
  local message_until = 0 -- tick until which a message from Arm stays in the second line

  ---The first line names the session. The second line says what it does, and
  ---what a recording still needs.
  local function update_status()
    local song = renoise.song()
    local S = model.S
    local text, what_now = "No takes in this song yet.", "Press Arm to start."
    local arm_text, arm_color = "Arm", { 0, 0, 0 }
    if S and song then
      local track = song.tracks[S.track]
      local parts = { ("Track %02d %s"):format(S.track, fit(track and track.name or "?", 28)) }
      if #S.tl.slots == 1 then
        parts[#parts + 1] = ("pattern %d"):format(S.tl.slots[1].pattern)
      else
        parts[#parts + 1] = ("%d patterns"):format(#S.tl.slots)
      end
      parts[#parts + 1] = ("%d lines"):format(S.tl.total)
      parts[#parts + 1] = #S.takes == 1 and "1 take" or ("%d takes"):format(#S.takes)
      text = table.concat(parts, "   ")
      local hearing = S.solo and ("Hearing take %d."):format(S.solo) or "Hearing the comp."
      local what, missing, note = session.readiness()
      if what == "stale" then
        what_now = "The loop or a pattern length changed. These takes can no longer be used here."
      elseif what == "recording" then
        what_now = "RECORDING. Each pass of the loop becomes a take."
        arm_color = { 200, 60, 50 }
      elseif what == "waiting" then
        if note then
          what_now = note .. "."
        elseif #missing > 0 then
          what_now = hearing .. "   To record: " .. table.concat(missing, ", ") .. "."
        else
          what_now = hearing .. "   Ready to record."
        end
        arm_color = { 190, 110, 40 }
      else
        what_now = "Not armed. Press Arm to record or to choose takes."
      end
      arm_text = S.armed and "Done" or "Arm"
      if link_box.value ~= S.link then
        updating = true
        link_box.value = S.link
        updating = false
      end
    end
    -- This runs several times a second: only touch the views when something changed.
    if text ~= last_status then
      status.text = fit(text, 100)
      last_status = text
    end
    if what_now ~= last_hint and state.tick >= message_until then
      hint.text = fit(what_now, 120)
      last_hint = what_now
    end
    local arm_key = arm_text .. arm_color[1]
    if arm_key ~= last_arm then
      arm_button.text = arm_text
      arm_button.color = arm_color
      last_arm = arm_key
    end
  end

  local function refresh()
    rebuild()
    -- Set a bar in an order that is valid at every step: first the lowest
    -- value, then the range, then the real value. The flag must always come
    -- back, or the bars and the link box would stop reacting.
    ---@param bar renoise.Views.ScrollBar
    local function set_bar(bar, total, page, value)
      bar.value = bar.min
      bar.pagestep = 1
      bar.max = math.max(total, page) + 1
      bar.pagestep = page
      bar.value = math.max(1, math.min(value, bar.max - page))
    end
    updating = true
    local ok, err = pcall(function()
      -- Without a session there is nothing to scroll: show a full, idle bar.
      set_bar(scrollbar, model.S and L.total or L.visible, L.visible, model.S and L.scroll or 1)
      -- The bar under the lanes moves through the takes.
      local room = math.max(1, state.takes_room)
      set_bar(lane_bar, model.S and #model.S.takes or 0, room, state.first_shown)
    end)
    updating = false
    if not ok then
      app.log("scroll bars: " .. tostring(err))
    end
    content:update()
    overlay:update()
    update_status()
    update_readout()
    state.dirty = false
  end

  local function move_cursor()
    if state.from < L.scroll or state.from >= L.scroll + L.visible then
      state.scroll = layout.reveal(L, state.from)
      state.dirty = true
    else
      overlay:update()
      update_readout()
    end
  end

  -- Actions --------------------------------------------------------------------

  ---Give the selected rows to the take of a lane (index into model.lanes).
  ---@param lane_index integer 0 is the comp.
  local function assign_to_lane(lane_index)
    local S = model.S
    local lane = model.lanes[lane_index + 1]
    if not S or not lane or lane.kind ~= "take" or S.rec then
      return
    end
    session.assign(not S.link and state.strip or nil, state.from, state.to, lane.take.id)
  end

  local function toggle_solo(lane_index)
    local S = model.S
    local lane = model.lanes[lane_index + 1]
    if not S or not lane or S.rec then
      return
    end
    if lane.kind == "take" and S.solo ~= lane.take.id then
      session.set_solo(lane.take.id)
    else
      session.set_solo(nil)
    end
  end

  local function arm_or_done()
    local S = session.get()
    if S and S.armed then
      session.disarm()
      return
    end
    -- Arm may need two answers: a new session, and unique patterns. Ask one at a time.
    local opts = {}
    local ok, message, code = session.arm(opts)
    for _ = 1, 2 do
      if ok or (code ~= "repeated" and code ~= "other") then
        break
      end
      if code == "repeated" then
        local answer = renoise.app():show_prompt(
          app.name,
          "A pattern is used twice in the loop. Each slot of the loop needs its own pattern, "
            .. "so that every pass can hold different notes.\n\nMake the looped patterns unique?",
          { "Make unique", "Cancel" }
        )
        if answer ~= "Make unique" then
          return
        end
        opts.make_unique = true
      else
        local answer = renoise.app():show_prompt(
          app.name,
          "This song has takes for another track or loop.\n\nStart a new session here? The old takes are removed.",
          { "New session", "Cancel" }
        )
        if answer ~= "New session" then
          return
        end
        opts.replace = true
      end
      ok, message, code = session.arm(opts)
    end
    if not ok and message then
      renoise.app():show_status(app.name .. ": " .. message)
      hint.text = fit(message, 120)
      last_hint = nil
      message_until = state.tick + math.floor(6000 / M.TICK_MS) -- about six seconds
    end
  end

  ---Bring earlier or later takes into view.
  ---@param d integer Lanes to move: negative for earlier takes.
  local function scroll_lanes(d)
    local S = model.S
    if not S or S.rec then
      return
    end
    local newest_first = math.max(1, #S.takes - state.takes_room + 1)
    local first = math.max(1, math.min(state.first_shown + d, newest_first))
    if first ~= state.first_shown then
      state.first_take = first
      state.dirty = true
    end
  end

  ---Change the zoom. With `anchor_y`, the row at that height stays where it is.
  ---@param zoom integer Index into `layout.ROW_HEIGHTS`: 1 is the largest row.
  ---@param anchor_y number?
  local function set_zoom(zoom, anchor_y)
    zoom = math.max(1, math.min(zoom, #layout.ROW_HEIGHTS))
    if zoom > state.zoom and L.visible >= L.total then
      return -- the whole loop is in view already
    end
    if zoom == state.zoom then
      return
    end
    if anchor_y and anchor_y >= layout.HEADER_H then
      local offset = anchor_y - layout.HEADER_H
      local row = L.scroll + math.floor(offset / L.row_h)
      local new_h = layout.row_height(zoom, L.total, M.VIEW_H)
      state.scroll = math.max(1, row - math.floor(offset / new_h))
    end
    state.zoom = zoom
    state.dirty = true
  end

  -- Mouse ------------------------------------------------------------------------

  local last_pos = nil ---@type { x: number, y: number }?

  ---@param event MouseEvent
  ---@return MouseEvent?
  local function mouse(event)
    local S = model.S
    local pos = event.position
    if event.type == "wheel" then
      local d = (event.direction == "up" and -1 or event.direction == "down" and 1 or 0)
      local ctrl = event.modifier_flags and event.modifier_flags.control
      if event.direction == "left" or event.direction == "right" then
        scroll_lanes(event.direction == "left" and -1 or 1) -- a sideways wheel moves through the takes
      elseif d ~= 0 and ctrl then
        scroll_lanes(d)
      elseif d ~= 0 then
        local shift = event.modifier_flags and event.modifier_flags.shift
        if shift or layout.hit(L, pos.x, pos.y).area == "gutter" then
          -- Shift, or the wheel over the line numbers: scroll.
          state.scroll =
            layout.clamp_scroll(L, state.scroll + d * math.max(1, math.floor(L.visible / 8)))
          stop_follow()
          state.dirty = true
        else
          set_zoom(state.zoom + d, pos.y) -- wheel up makes the rows larger
        end
      end
      return nil
    end
    if not S then
      return nil
    end
    -- Renoise 3.5.4 sometimes reports a move far away from the last one.
    if (event.type == "drag" or event.type == "move") and last_pos then
      if math.abs(pos.x - last_pos.x) > 300 or math.abs(pos.y - last_pos.y) > 300 then
        return nil
      end
    end
    last_pos = { x = pos.x, y = pos.y }
    local hit = layout.hit(L, pos.x, pos.y)
    if event.type == "down" and event.button == "left" then
      if hit.area == "header" then
        toggle_solo(hit.lane)
      elseif hit.area == "body" and (model.lanes[hit.lane + 1] or {}).kind == "take" then
        local unit = state.snap_beat and model.lpb or 1
        state.lane, state.strip = hit.lane, hit.strip
        state.anchor = hit.row
        state.from, state.to = layout.snap(S.tl, hit.row, unit)
        state.drag = { lane = hit.lane, strip = hit.strip, row = hit.row }
        overlay:update()
        update_readout()
      end
    elseif event.type == "drag" and state.drag then
      local row = hit.row
      if not row then
        row = pos.y < layout.HEADER_H and L.scroll or (L.scroll + L.visible - 1)
      end
      if row ~= state.drag.row then
        state.drag.row = row
        overlay:update()
      end
    elseif event.type == "up" and state.drag then
      if hit.row then
        state.drag.row = hit.row
      end
      state.from, state.to = drag_rows()
      local lane = state.drag.lane
      state.drag = nil
      if lane > 0 then
        assign_to_lane(lane)
      end
      overlay:update()
      update_readout()
    elseif
      event.type == "double"
      and hit.area == "body"
      and (model.lanes[hit.lane + 1] or {}).kind == "take"
    then
      state.lane, state.strip = hit.lane, hit.strip
      state.from, state.to, state.anchor = 1, L.total, 1
      assign_to_lane(hit.lane)
    end
    return nil
  end

  -- Keyboard ---------------------------------------------------------------------

  ---@param key KeyEvent
  ---@return boolean handled
  local function handle_key(key)
    local S = model.S
    if not S then
      return false
    end
    local name = key.name
    local shift = key.modifier_flags and key.modifier_flags.shift
    local ctrl = key.modifier_flags and key.modifier_flags.control
    local unit = (state.snap_beat and not ctrl) and model.lpb or 1
    if
      name == "up"
      or name == "down"
      or name == "prior"
      or name == "next"
      or name == "home"
      or name == "end"
    then
      -- With Shift, one end of the selection stays on the anchor and the other moves.
      local head_is_top = shift and state.anchor > state.from
      local target
      if name == "up" then
        target = (head_is_top or not shift) and state.from - 1
          or (layout.snap(S.tl, state.to, unit)) - 1
      elseif name == "down" then
        target = head_is_top and select(2, layout.snap(S.tl, state.from, unit)) + 1 or state.to + 1
      elseif name == "prior" then
        target = (head_is_top and state.from or state.to) - L.visible
      elseif name == "next" then
        target = (head_is_top and state.from or state.to) + L.visible
      elseif name == "home" then
        target = 1
      else
        target = L.total
      end
      target = math.max(1, math.min(target, L.total))
      local a, b = layout.snap(S.tl, target, unit)
      if shift then
        local a1, a2 = layout.snap(S.tl, state.anchor, unit)
        state.from, state.to = math.min(a1, a), math.max(a2, b)
      else
        state.from, state.to, state.anchor = a, b, a
      end
      stop_follow()
      local focus = (name == "up" or name == "prior" or name == "home") and state.from or state.to
      if focus < L.scroll or focus >= L.scroll + L.visible then
        state.scroll = layout.reveal(L, focus)
        state.dirty = true
      else
        overlay:update()
        update_readout()
      end
      return true
    elseif name == "left" or name == "right" then
      local d = name == "left" and -1 or 1
      -- At the edge of the view, the arrow brings the next take into view.
      local at_left = state.lane <= 1 and (S.link or state.strip == "notes")
      local at_right = state.lane >= state.take_lanes and (S.link or state.strip == "moves")
      if d < 0 and at_left and state.hidden > 0 then
        scroll_lanes(-1)
        return true
      elseif d > 0 and at_right and state.hidden_after > 0 then
        scroll_lanes(1)
        return true
      end
      if S.link then
        state.lane = math.max(1, math.min(state.lane + d, state.take_lanes))
      else
        local pos = state.lane * 2 + (state.strip == "moves" and 1 or 0) + d
        pos = math.max(2, math.min(pos, math.max(1, state.take_lanes) * 2 + 1))
        state.lane, state.strip = math.floor(pos / 2), pos % 2 == 1 and "moves" or "notes"
      end
      overlay:update()
      update_readout()
      return true
    elseif name == "return" then
      assign_to_lane(state.lane)
      return true
    elseif name == "del" or name == "back" then
      if not S.rec then
        session.assign(not S.link and state.strip or nil, state.from, state.to, nil)
      end
      return true
    elseif name == "s" and not ctrl then
      toggle_solo(state.lane)
      return true
    elseif #name == 1 and name:match "%d" and not ctrl then
      local n = tonumber(name) or 0
      if n == 0 then
        session.set_solo(nil)
      else
        assign_to_lane(n)
      end
      return true
    end
    return false
  end

  ---@param _ renoise.Dialog
  ---@param key KeyEvent
  ---@return KeyEvent?
  local function key_handler(_, key)
    local ok, handled = pcall(handle_key, key)
    if not ok then
      app.log("key handler: " .. tostring(handled))
      return key
    end
    if handled then
      return nil
    end
    return key -- Space, F keys and the rest still reach Renoise
  end

  -- Timer ------------------------------------------------------------------------

  local dialog = nil ---@type renoise.Dialog?

  local function tick()
    if dialog and not dialog.visible then
      scope.release()
      return
    end
    state.tick = state.tick + 1
    local S = session.get()
    if S ~= model.S then
      state.dirty = true
    end
    if S and S.rec and state.tick % 6 == 0 then
      state.dirty = true -- show the notes of the pass in progress
    end
    if state.tick % 5 == 0 and not state.dirty then
      update_status() -- edit mode, follow and play change outside the tool
    end
    local row = S and S.playhead
    if row and state.follow and S and S.armed then
      local scroll = layout.follow(L, row)
      if scroll ~= state.scroll then
        state.scroll = scroll
        state.dirty = true
      end
    end
    if state.dirty then
      refresh()
    end
    local y = row and layout.row_y(L, row)
    if y then
      playhead.origin = { x = 0, y = math.floor(y + L.row_h / 2) - 1 }
      if not playhead.visible then
        playhead.visible = true
      end
    elseif playhead.visible then
      playhead.visible = false
    end
  end

  -- Layout of the dialog -----------------------------------------------------------

  local BUTTON_H = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT
  local GAP = 6

  ---A framed group of controls in the toolbar.
  ---@param views renoise.Views.View[]
  ---@return renoise.Views.View
  local function group(views)
    local row = vb:row { background = "group", margin = 5, spacing = GAP }
    for _, view in ipairs(views) do
      row:add_view(view)
    end
    return row
  end

  ---A checkbox with its label. The label has the same tooltip.
  ---@param box renoise.Views.View
  ---@param label string
  ---@param tooltip string
  ---@return renoise.Views.View
  local function option(box, label, tooltip)
    return vb:row {
      spacing = 4,
      vb:vertical_aligner { mode = "center", height = BUTTON_H, box },
      vb:vertical_aligner {
        mode = "center",
        height = BUTTON_H,
        vb:text { text = label, tooltip = tooltip },
      },
    }
  end

  local TIP_LINK =
    "On: a swipe takes the notes and the parameter moves of a take together.\nOff: a swipe takes only the strip that you drag on, notes or moves."
  local TIP_SNAP = "On: swipes and the cursor move by whole beats.\nOff: they move by single lines."
  local TIP_FOLLOW = "Scroll the view with the playhead."

  arm_button = vb:button {
    id = "arm",
    text = "Arm",
    width = 96,
    height = BUTTON_H,
    tooltip = "Arm: bind the takes to the selected track and to the loop, and turn pattern follow on.\nThen play with edit mode on, and each pass of the loop becomes a take.\nThe pattern matrix shows the armed track in orange. While you record, its slots flash red.\nDone: stop, and keep the comp in the pattern. The takes stay in the song.",
    notifier = app.guard(arm_or_done),
  }
  link_box = vb:checkbox {
    id = "link",
    value = true,
    tooltip = TIP_LINK,
    notifier = app.guard(function(value)
      if not updating then
        session.set_link(value)
      end
    end),
  }
  scrollbar = vb:scrollbar {
    id = "scroll",
    width = M.SCROLL_W,
    height = M.CANVAS_H,
    min = 1,
    max = L.total + 1,
    pagestep = L.visible,
    value = 1,
    notifier = app.guard(function(value)
      if not updating then
        state.scroll = value
        stop_follow()
        state.dirty = true
      end
    end),
  }
  lane_bar = vb:scrollbar {
    id = "lane_scroll",
    width = M.CANVAS_W,
    height = M.SCROLL_W,
    min = 1,
    max = 2,
    pagestep = 1,
    value = 1,
    tooltip = "Move through the takes. Earlier takes are on the left.\nThe arrow keys at the edge of the view, a sideways wheel, and Ctrl + wheel do the same.",
    notifier = app.guard(function(value)
      if not updating then
        state.first_take = value
        state.dirty = true
      end
    end),
  }
  local new_button = vb:button {
    id = "new",
    text = "New session",
    width = 96,
    height = BUTTON_H,
    tooltip = "Remove all takes of this song and start again. The track keeps what it holds now.",
    notifier = app.guard(function()
      local S = session.get()
      if S and #S.takes > 0 then
        local answer = renoise.app():show_prompt(
          app.name,
          "Remove all takes of this song and start again?\n\nThe track keeps what it holds now.",
          { "Remove takes", "Cancel" }
        )
        if answer ~= "Remove takes" then
          return
        end
      end
      session.reset()
    end),
  }
  local delete_button = vb:button {
    id = "delete",
    text = "Delete take",
    width = 96,
    height = BUTTON_H,
    tooltip = "Delete the take under the cursor. Click in a take lane first.",
    notifier = app.guard(function()
      local lane = model.lanes[state.lane + 1]
      if lane and lane.kind == "take" then
        session.delete_take(lane.take.id)
      end
    end),
  }
  local snap_box = vb:checkbox {
    id = "snap",
    value = true,
    tooltip = TIP_SNAP,
    notifier = function(value)
      state.snap_beat = value
    end,
  }
  follow_box = vb:checkbox {
    id = "follow",
    value = true,
    tooltip = TIP_FOLLOW,
    notifier = function(value)
      state.follow = value
    end,
  }
  local zoom_out = vb:button {
    id = "zoom_out",
    text = "-",
    width = 28,
    height = BUTTON_H,
    tooltip = "Zoom out: smaller rows, so more lines fit in the view.\nThe mouse wheel over the lanes does the same.",
    notifier = function()
      set_zoom(state.zoom + 1)
    end,
  }
  local zoom_in = vb:button {
    id = "zoom_in",
    text = "+",
    width = 28,
    height = BUTTON_H,
    tooltip = "Zoom in: larger rows, with every note as text.\nThe mouse wheel over the lanes does the same.",
    notifier = function()
      set_zoom(state.zoom - 1)
    end,
  }
  local help_button = vb:button {
    id = "help",
    text = "?",
    width = 28,
    height = BUTTON_H,
    tooltip = "Show how to use the view.",
    notifier = function()
      renoise.app():show_message(M.HELP)
    end,
  }
  local zoom_label = vb:vertical_aligner {
    mode = "center",
    height = BUTTON_H,
    vb:text { text = "Zoom" },
  }

  local root = vb:column {
    id = "root",
    margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN,
    spacing = renoise.ViewBuilder.DEFAULT_DIALOG_SPACING,
    -- Toolbar: four framed groups, spread over the width of the lanes.
    vb:horizontal_aligner {
      id = "toolbar",
      mode = "justify",
      width = FULL_W,
      group { arm_button, new_button, delete_button },
      group {
        option(link_box, "Link notes and moves", TIP_LINK),
        vb:space { width = GAP },
        option(snap_box, "Snap to beats", TIP_SNAP),
      },
      group {
        option(follow_box, "Follow", TIP_FOLLOW),
        vb:space { width = GAP },
        zoom_label,
        zoom_out,
        zoom_in,
      },
      group { help_button },
    },
    vb:column {
      background = "group",
      margin = 5,
      width = FULL_W,
      status,
      hint,
    },
    vb:column {
      background = "border",
      vb:row {
        vb:stack {
          id = "stack",
          mouse_events = { "down", "up", "double", "drag", "wheel" },
          mouse_handler = app.safe(mouse),
          content,
          overlay,
          playhead,
        },
        scrollbar,
      },
      lane_bar,
    },
    vb:row {
      background = "group",
      margin = 5,
      width = FULL_W,
      readout,
    },
  }

  scope.add(session.listen(function()
    state.dirty = true
  end))
  scope.timer(app.safe(tick), M.TICK_MS)
  refresh()

  return vb,
    root,
    {
      key_handler = key_handler,
      key_options = { send_key_repeat = true, send_key_release = false },
      scope = scope,
      attach = function(d)
        dialog = d
      end,
      -- For `just eval`: drive the view without a mouse.
      mouse = mouse,
      key = handle_key,
      state = state,
      refresh = refresh,
      layout = function()
        return L
      end,
    }
end

return M
