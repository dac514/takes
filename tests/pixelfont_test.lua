local t = require "tests.helper"
local font = require "src.pixelfont"

local function pixels(char)
  local n = 0
  for _, run in ipairs(font.runs(char)) do
    n = n + run[3]
  end
  return n
end

t.eq(#font.runs " ", 0, "space has no runs")
t.eq(pixels "-", 5, "dash is one row of five pixels")
t.eq(#font.runs "-", 1, "dash is one run")
t.eq(font.runs("-")[1][2], 3, "dash is in the middle row")
t.eq(pixels "T", 5 + 6, "T has a top bar and a stem")
t.eq(pixels "#", 20, "sharp sign")
t.check(font.runs "c" == font.runs "C", "lower case uses the upper case glyph")
t.check(#font.runs "~" == #font.runs "-", "unknown characters fall back to the dash")

-- Every run stays inside the 5x7 cell.
local ok = true
for _, char in ipairs { "A", "G", "M", "Q", "W", "0", "4", "8", "#", "*", ":" } do
  for _, run in ipairs(font.runs(char)) do
    if run[1] < 0 or run[1] + run[3] > font.WIDTH or run[2] < 0 or run[2] >= font.HEIGHT then
      ok = false
    end
  end
end
t.check(ok, "runs stay inside the cell")

t.eq(font.width "", 0, "width: empty")
t.eq(font.width "C", 5, "width: one character")
t.eq(font.width "C-4", 17, "width: three characters")

-- draw offsets each character and reports rectangles of height 1.
local rects = {}
font.draw("--", 10, 20, function(x, y, w, h)
  rects[#rects + 1] = { x, y, w, h }
end)
t.eq(#rects, 2, "draw: one rectangle for each dash")
t.eq(rects[1][1], 10, "draw: first x")
t.eq(rects[1][2], 23, "draw: y of the middle row")
t.eq(rects[2][1], 16, "draw: second character is one advance further")
t.eq(rects[1][4], 1, "draw: height 1")

-- A scale makes every font pixel larger.
rects = {}
font.draw("--", 10, 20, function(x, y, w, h)
  rects[#rects + 1] = { x, y, w, h }
end, 2)
t.eq(rects[1][2], 26, "scale 2: y of the middle row")
t.eq(rects[1][3], 10, "scale 2: width")
t.eq(rects[1][4], 2, "scale 2: height")
t.eq(rects[2][1], 22, "scale 2: the advance is doubled")

t.done()
