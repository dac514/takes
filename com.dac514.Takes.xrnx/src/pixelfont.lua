--[[
  Pure Lua (no renoise.*). A 5x7 pixel font as rectangles.

  The Renoise canvas has no text function. So the view draws its own letters:
  each glyph is a list of horizontal runs of pixels, and the view fills one
  small rectangle for each run. The look is close to the pattern editor.
]]

local M = {}

M.WIDTH = 5
M.HEIGHT = 7
---Distance from one character to the next.
M.ADVANCE = 6

-- Seven rows of five pixels for each glyph. "#" is a set pixel.
local GLYPHS = {
  ["A"] = ".###. #...# #...# ##### #...# #...# #...#",
  ["B"] = "####. #...# #...# ####. #...# #...# ####.",
  ["C"] = ".###. #...# #.... #.... #.... #...# .###.",
  ["D"] = "####. #...# #...# #...# #...# #...# ####.",
  ["E"] = "##### #.... #.... ####. #.... #.... #####",
  ["F"] = "##### #.... #.... ####. #.... #.... #....",
  ["G"] = ".###. #...# #.... #.### #...# #...# .###.",
  ["H"] = "#...# #...# #...# ##### #...# #...# #...#",
  ["I"] = ".###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.",
  ["J"] = "..### ...#. ...#. ...#. ...#. #..#. .##..",
  ["K"] = "#...# #..#. #.#.. ##... #.#.. #..#. #...#",
  ["L"] = "#.... #.... #.... #.... #.... #.... #####",
  ["M"] = "#...# ##.## #.#.# #.#.# #...# #...# #...#",
  ["N"] = "#...# ##..# #.#.# #..## #...# #...# #...#",
  ["O"] = ".###. #...# #...# #...# #...# #...# .###.",
  ["P"] = "####. #...# #...# ####. #.... #.... #....",
  ["Q"] = ".###. #...# #...# #...# #.#.# #..#. .##.#",
  ["R"] = "####. #...# #...# ####. #.#.. #..#. #...#",
  ["S"] = ".#### #.... #.... .###. ....# ....# ####.",
  ["T"] = "##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..",
  ["U"] = "#...# #...# #...# #...# #...# #...# .###.",
  ["V"] = "#...# #...# #...# #...# #...# .#.#. ..#..",
  ["W"] = "#...# #...# #...# #.#.# #.#.# ##.## #...#",
  ["X"] = "#...# #...# .#.#. ..#.. .#.#. #...# #...#",
  ["Y"] = "#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..",
  ["Z"] = "##### ....# ...#. ..#.. .#... #.... #####",
  ["0"] = ".###. #...# #..## #.#.# ##..# #...# .###.",
  ["1"] = "..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.",
  ["2"] = ".###. #...# ....# ...#. ..#.. .#... #####",
  ["3"] = "####. ....# ....# .###. ....# ....# ####.",
  ["4"] = "...#. ..##. .#.#. #..#. ##### ...#. ...#.",
  ["5"] = "##### #.... ####. ....# ....# #...# .###.",
  ["6"] = ".###. #.... #.... ####. #...# #...# .###.",
  ["7"] = "##### ....# ...#. ..#.. .#... .#... .#...",
  ["8"] = ".###. #...# #...# .###. #...# #...# .###.",
  ["9"] = ".###. #...# #...# .#### ....# ....# .###.",
  ["-"] = "..... ..... ..... ##### ..... ..... .....",
  ["#"] = ".#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.",
  ["."] = "..... ..... ..... ..... ..... .##.. .##..",
  [":"] = "..... .##.. .##.. ..... .##.. .##.. .....",
  ["+"] = "..... ..#.. ..#.. ##### ..#.. ..#.. .....",
  ["/"] = "....# ....# ...#. ..#.. .#... #.... #....",
  [">"] = ".#... ..#.. ...#. ....# ...#. ..#.. .#...",
  ["<"] = "...#. ..#.. .#... #.... .#... ..#.. ...#.",
  ["*"] = "..... #.#.# .###. ##### .###. #.#.# .....",
  [" "] = "..... ..... ..... ..... ..... ..... .....",
}

---@type table<string, integer[][]>
local cache = {}

---Horizontal runs of a glyph: a list of { x, y, width }, with x and y from 0.
---An unknown character gives the runs of "-".
---@param char string One character. Lower case letters use the upper case glyph.
---@return integer[][]
function M.runs(char)
  local key = char:upper()
  local found = cache[key]
  if found then
    return found
  end
  local rows = GLYPHS[key] or GLYPHS["-"]
  local runs = {}
  local y = 0
  for row in rows:gmatch "%S+" do
    local start = nil
    for x = 1, M.WIDTH + 1 do
      local set = row:sub(x, x) == "#"
      if set and not start then
        start = x
      elseif not set and start then
        runs[#runs + 1] = { start - 1, y, x - start }
        start = nil
      end
    end
    y = y + 1
  end
  cache[key] = runs
  return runs
end

---@param text string
---@return integer width In pixels, without the gap after the last character.
function M.width(text)
  if #text == 0 then
    return 0
  end
  return #text * M.ADVANCE - (M.ADVANCE - M.WIDTH)
end

---Call `emit(x, y, w, h)` for each rectangle of the text.
---@param text string
---@param x number Left edge.
---@param y number Top edge.
---@param emit fun(x: number, y: number, w: number, h: number)
---@param scale integer? Size of one font pixel. Default 1.
function M.draw(text, x, y, emit, scale)
  scale = scale or 1
  for i = 1, #text do
    local runs = M.runs(text:sub(i, i))
    local cx = x + (i - 1) * M.ADVANCE * scale
    for r = 1, #runs do
      local run = runs[r]
      emit(cx + run[1] * scale, y + run[2] * scale, run[3] * scale, scale)
    end
  end
end

return M
