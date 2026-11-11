local t = require "tests.helper"
local layout = require "src.layout"
local timeline = require "src.timeline"

local L = layout.new { total = 64, lanes = 3, note_cols = 2, row_h = 12, view_h = 384, scroll = 1 }
t.eq(L.visible, 32, "visible rows: view height / row height")
t.eq(L.height, layout.HEADER_H + 32 * 12, "height")
t.eq(L.notes_w, 3 + 3 + 2 * 20, "notes strip width")
t.eq(
  L.width,
  layout.GUTTER_W + layout.COMP_GAP + 4 * (L.lane_w + layout.LANE_GAP),
  "width for the comp and three takes"
)
t.eq(layout.lane_x(L, 0), layout.GUTTER_W, "the comp lane starts after the gutter")
t.eq(
  layout.lane_x(L, 1),
  layout.GUTTER_W + L.lane_w + layout.LANE_GAP + layout.COMP_GAP,
  "take 1 starts after the comp gap"
)

-- Rows.
t.eq(layout.row_y(L, 1), layout.HEADER_H, "row 1 is under the header")
t.eq(layout.row_y(L, 32), layout.HEADER_H + 31 * 12, "last visible row")
t.eq(layout.row_y(L, 33), nil, "row below the window")
local scrolled =
  layout.new { total = 64, lanes = 3, note_cols = 2, row_h = 12, view_h = 384, scroll = 40 }
t.eq(scrolled.scroll, 33, "scroll is clamped to the last page")
t.eq(layout.row_y(scrolled, 33), layout.HEADER_H, "scrolled: first visible row")
t.eq(layout.row_y(scrolled, 1), nil, "scrolled: row above the window")
local short =
  layout.new { total = 16, lanes = 1, note_cols = 1, row_h = 12, view_h = 384, scroll = 5 }
t.eq(short.visible, 16, "a short loop shows all its rows")
t.eq(short.scroll, 1, "a short loop cannot scroll")

-- Hit testing.
local h = layout.hit(L, 5, 100)
t.eq(h.area, "gutter", "hit: gutter")
t.eq(h.row, 1 + math.floor((100 - layout.HEADER_H) / 12), "hit: gutter row")
h = layout.hit(L, layout.lane_x(L, 0) + 10, 5)
t.eq(h.area, "header", "hit: comp header")
t.eq(h.lane, 0, "hit: comp header lane")
local nx = layout.strip(L, 2, "notes")
h = layout.hit(L, nx + 10, layout.HEADER_H + 12 * 4 + 3)
t.eq(h.area, "body", "hit: body")
t.eq(h.lane, 2, "hit: lane")
t.eq(h.strip, "notes", "hit: notes strip")
t.eq(h.row, 5, "hit: row")
local mx = layout.strip(L, 2, "moves")
h = layout.hit(L, mx + 10, layout.HEADER_H + 2)
t.eq(h.strip, "moves", "hit: moves strip")
t.eq(h.row, 1, "hit: first row")
h = layout.hit(L, layout.lane_x(L, 1) - 2, layout.HEADER_H + 2)
t.eq(h.area, "none", "hit: the gap between lanes")
h = layout.hit(L, nx + 10, L.height + 5)
t.eq(h.area, "none", "hit: below the rows")
h = layout.hit(scrolled, nx + 10, layout.HEADER_H + 2)
t.eq(h.row, 33, "hit: row with scroll")

-- Snapping to beats, counted from each pattern start.
local tl =
  timeline.new { { seq = 1, pattern = 1, lines = 10 }, { seq = 2, pattern = 2, lines = 16 } }
local from, to = layout.snap(tl, 6, 4)
t.eq(from, 5, "snap: beat start")
t.eq(to, 8, "snap: beat end")
from, to = layout.snap(tl, 10, 4)
t.eq(from, 9, "snap: last beat of a pattern starts on the beat")
t.eq(to, 10, "snap: last beat of a pattern stops at the pattern end")
from, to = layout.snap(tl, 12, 4)
t.eq(from, 11, "snap: beats restart at the next pattern")
t.eq(to, 14, "snap: first beat of the next pattern")
from, to = layout.snap(tl, 7, 1)
t.eq(from, 7, "snap: line unit from")
t.eq(to, 7, "snap: line unit to")
from, to = layout.snap(tl, 99, 4)
t.eq(to, 26, "snap: a row past the end is clamped")

-- A fixed width: as many lanes as fit, and the lanes share what is left.
local fixed = layout.new {
  total = 64,
  lanes = 0,
  note_cols = 2,
  row_h = 12,
  view_h = 480,
  scroll = 1,
  width = 842,
}
t.eq(fixed.width, 842, "fixed width: the width is kept")
t.eq(fixed.lanes, 8, "fixed width: the comp and eight takes fit with two note columns")
t.check(
  layout.lane_x(fixed, 8) + fixed.lane_w <= 842,
  "fixed width: the last lane ends inside the view"
)
t.check(
  842 - (layout.lane_x(fixed, 8) + fixed.lane_w) < 16,
  "fixed width: little space is left on the right"
)
local wide = layout.new {
  total = 64,
  lanes = 0,
  note_cols = 4,
  row_h = 12,
  view_h = 480,
  scroll = 1,
  width = 842,
}
t.eq(wide.lanes, 5, "fixed width: fewer lanes with four note columns")
t.check(wide.moves_w > fixed.moves_w, "fixed width: the space left over widens the moves strips")
local tiny = layout.new {
  total = 64,
  lanes = 0,
  note_cols = 4,
  row_h = 12,
  view_h = 480,
  scroll = 1,
  width = 100,
}
t.eq(tiny.lanes, 1, "fixed width: always the comp and one take")

-- Row heights: zoom levels, and rows that always fill the view.
t.eq(layout.row_height(1, 64, 480), 12, "row height: largest level")
t.eq(layout.row_height(#layout.ROW_HEIGHTS, 512, 480), 2, "row height: smallest level")
t.eq(layout.row_height(99, 512, 480), 2, "row height: the level is clamped")
t.eq(layout.row_height(1, 16, 480), 30, "row height: a short loop gets taller rows")
t.eq(layout.row_height(7, 192, 480), 2.5, "row height: zoomed out, the loop fills the view exactly")
local fit =
  layout.new { total = 192, lanes = 1, note_cols = 2, row_h = 2.5, view_h = 480, scroll = 1 }
t.eq(fit.visible, 192, "fraction row height: all rows are visible")
t.eq(fit.height, layout.HEADER_H + 480, "fraction row height: the rows fill the view")
t.eq(layout.row_y(fit, 3), layout.HEADER_H + 5, "fraction row height: row position")
t.eq(
  layout.hit(fit, layout.lane_x(fit, 1) + 5, layout.HEADER_H + 6).row,
  3,
  "fraction row height: hit row"
)
for _, h in ipairs(layout.ROW_HEIGHTS) do
  t.eq(480 % h, 0, ("row height %d divides the view height"):format(h))
end

-- Scrolling.
t.eq(layout.reveal(L, 10), 1, "reveal: visible row keeps the scroll")
t.eq(layout.reveal(L, 40), 9, "reveal: row below")
t.eq(layout.reveal(scrolled, 20), 20, "reveal: row above")
t.eq(layout.follow(L, 20), 1, "follow: playhead in the window")
t.eq(layout.follow(L, 33), 33, "follow: turn the page")
local long =
  layout.new { total = 100, lanes = 1, note_cols = 1, row_h = 12, view_h = 384, scroll = 1 }
t.eq(layout.follow(long, 97), 69, "follow: the last page is clamped")

t.done()
