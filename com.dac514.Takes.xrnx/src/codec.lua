--[[
  Pure Lua (no renoise.*). Text format for a session, kept in the song through
  `renoise.song().tool_data`.

  The format is lines of words and numbers. It is parsed by hand: the data
  comes from a song file, so it must never be run as Lua code.

    TAKES 1                       header and format version
    track 3                       armed track
    next 5                        id of the next take
    link 1                        "link notes and moves" switch
    solo 0                        take that is auditioned, 0 for the comp
    slot <seq> <pattern> <lines>  one line per looped sequence slot
    base <key> <value>            parameter value before any take moved it
    take <id> <rows> <overlapped>
    n <row> <col> <note> <ins> <vol> <pan> <dly> <fxn> <fxa>
    f <row> <col> <number> <amount>
    e <device> <param> <playmode> [device name]   an envelope of the take; its points follow
    p <time> <value> <scaling>
    seg <layer> <from> <to> <take>
    end
]]

local M = {}

M.MAGIC = "TAKES"
M.VERSION = 1

---@class SessionData
---@field track integer
---@field next_id integer
---@field link boolean
---@field solo integer?
---@field slots { seq: integer, pattern: integer, lines: integer }[]
---@field base table<string, number>
---@field takes Take[]
---@field comp Comp

---@param n number
---@return string
local function num(n)
  if n == math.floor(n) then
    return ("%d"):format(n)
  end
  return ("%.6f"):format(n)
end

---@param t table<integer, any>
---@return integer[]
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

---@param data SessionData
---@return string
function M.encode(data)
  local out = {}
  local function add(...)
    local words = { ... }
    for i, w in ipairs(words) do
      words[i] = type(w) == "number" and num(w) or tostring(w)
    end
    out[#out + 1] = table.concat(words, " ")
  end
  add(M.MAGIC, M.VERSION)
  add("track", data.track)
  add("next", data.next_id)
  add("link", data.link and 1 or 0)
  add("solo", data.solo or 0)
  for _, s in ipairs(data.slots) do
    add("slot", s.seq, s.pattern, s.lines)
  end
  local base_keys = {}
  for key in pairs(data.base or {}) do
    base_keys[#base_keys + 1] = key
  end
  table.sort(base_keys)
  for _, key in ipairs(base_keys) do
    add("base", key, data.base[key])
  end
  for _, take in ipairs(data.takes) do
    add("take", take.id, take.rows, take.overlapped and 1 or 0)
    for _, row in ipairs(sorted_keys(take.content.notes)) do
      local cols = take.content.notes[row]
      for _, col in ipairs(sorted_keys(cols)) do
        local c = cols[col]
        add("n", row, col, c[1], c[2], c[3], c[4], c[5], c[6], c[7])
      end
    end
    for _, row in ipairs(sorted_keys(take.content.fx)) do
      local cols = take.content.fx[row]
      for _, col in ipairs(sorted_keys(cols)) do
        add("f", row, col, cols[col][1], cols[col][2])
      end
    end
    local env_keys = {}
    for key in pairs(take.content.auto) do
      env_keys[#env_keys + 1] = key
    end
    table.sort(env_keys)
    for _, key in ipairs(env_keys) do
      local env = take.content.auto[key]
      if env.name and env.name ~= "" then
        add("e", env.device, env.param, env.playmode, (env.name:gsub("%s+", " ")))
      else
        add("e", env.device, env.param, env.playmode)
      end
      for _, p in ipairs(env.points) do
        add("p", p[1], p[2], p[3] or 0)
      end
    end
  end
  for _, layer in ipairs { "notes", "moves" } do
    for _, s in ipairs(data.comp[layer]) do
      add("seg", layer, s.from, s.to, s.take)
    end
  end
  add "end"
  return table.concat(out, "\n") .. "\n"
end

---@param text string?
---@return SessionData? data, string? error
function M.decode(text)
  if type(text) ~= "string" or text == "" then
    return nil, "no data"
  end
  ---@type SessionData
  local data = {
    track = 0,
    next_id = 1,
    link = true,
    solo = nil,
    slots = {},
    base = {},
    takes = {},
    comp = { notes = {}, moves = {} },
  }
  local take, env
  local first, ended = true, false
  for line in text:gmatch "[^\r\n]+" do
    local w = {}
    for word in line:gmatch "%S+" do
      w[#w + 1] = word
    end
    local tag = w[1]
    ---@param i integer
    ---@return number
    local function n(i)
      local v = tonumber(w[i])
      if not v then
        error(("bad number in '%s'"):format(line), 0)
      end
      return v
    end
    local ok, err = pcall(function()
      if first then
        first = false
        if tag ~= M.MAGIC then
          error("not a takes session", 0)
        end
        if n(2) > M.VERSION then
          error(("made by a newer version (%d)"):format(n(2)), 0)
        end
      elseif tag == "track" then
        data.track = n(2)
      elseif tag == "next" then
        data.next_id = n(2)
      elseif tag == "link" then
        data.link = n(2) ~= 0
      elseif tag == "solo" then
        data.solo = n(2) ~= 0 and n(2) or nil
      elseif tag == "slot" then
        data.slots[#data.slots + 1] = { seq = n(2), pattern = n(3), lines = n(4) }
      elseif tag == "base" then
        data.base[w[2]] = n(3)
      elseif tag == "take" then
        take = {
          id = n(2),
          rows = n(3),
          overlapped = n(4) ~= 0 or nil,
          content = { notes = {}, fx = {}, auto = {} },
        }
        env = nil
        data.takes[#data.takes + 1] = take
      elseif tag == "n" and take then
        local row, col = n(2), n(3)
        take.content.notes[row] = take.content.notes[row] or {}
        take.content.notes[row][col] = { n(4), n(5), n(6), n(7), n(8), n(9), n(10) }
      elseif tag == "f" and take then
        local row, col = n(2), n(3)
        take.content.fx[row] = take.content.fx[row] or {}
        take.content.fx[row][col] = { n(4), n(5) }
      elseif tag == "e" and take then
        env = { device = n(2), param = n(3), playmode = n(4), points = {} }
        if w[5] then
          env.name = table.concat(w, " ", 5)
        end
        take.content.auto[n(2) .. ":" .. n(3)] = env
      elseif tag == "p" and env then
        env.points[#env.points + 1] = { n(2), n(3), n(4) }
      elseif tag == "seg" then
        local list = data.comp[w[2]]
        if not list then
          error(("unknown layer '%s'"):format(tostring(w[2])), 0)
        end
        list[#list + 1] = { from = n(3), to = n(4), take = n(5) }
      elseif tag == "end" then
        ended = true
      end
    end)
    if not ok then
      return nil, tostring(err)
    end
    if ended then
      break
    end
  end
  if not ended then
    return nil, "the data is cut off"
  end
  if data.track < 1 or #data.slots == 0 then
    return nil, "the data has no track or no loop"
  end
  return data, nil
end

return M
