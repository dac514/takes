--[[
  Reads and writes the armed track of the looped patterns. Thin: the data
  shapes and all decisions live in the pure modules.

  Writing costs far more than reading in Renoise (about 10 to 150 microseconds
  for each field that changes, against less than 1 for a read). So `write`
  compares every field with the pattern first and only sets what differs.
]]

local envelopes = require "src.envelopes"
local timeline = require "src.timeline"

local M = {}

---@param track renoise.Track
---@param automation renoise.PatternTrackAutomation
---@return integer? device, integer? param, string? device_name
local function automation_target(track, automation)
  local dev, par = automation.dest_device, automation.dest_parameter
  if not dev or not par then
    return nil, nil, nil
  end
  for d, device in ipairs(track.devices) do
    if rawequal(device, dev) then
      for p, parameter in ipairs(device.parameters) do
        if rawequal(parameter, par) then
          return d, p, device.name
        end
      end
    end
  end
  return nil, nil, nil
end

---The parameter that an envelope belongs to, or nil when the device is gone,
---was replaced by another device, or the parameter cannot be automated.
---@param track renoise.Track
---@param env Envelope
---@return renoise.DeviceParameter?
local function envelope_parameter(track, env)
  if env.device < 1 or env.device > #track.devices then
    return nil
  end
  local device = track:device(env.device)
  if env.name and device.name ~= env.name then
    return nil
  end
  if env.param < 1 or env.param > #device.parameters then
    return nil
  end
  local parameter = device:parameter(env.param)
  return parameter.is_automatable and parameter or nil
end

---Remove the envelopes that cannot be written to this track. So the tool
---never expects to find something in the track that it could not put there.
---@param song renoise.Song
---@param track_index integer
---@param content Content
function M.prune(song, track_index, content)
  local track = song:track(track_index)
  for key, env in pairs(content.auto) do
    if not envelope_parameter(track, env) then
      content.auto[key] = nil
    end
  end
end

---Read the rows `from_row..to_row` of the track into `content`. Rows in the
---range that are empty in the pattern are removed from `content`.
---@param song renoise.Song
---@param tl Timeline
---@param track_index integer
---@param content Content
---@param from_row integer
---@param to_row integer
function M.read(song, tl, track_index, content, from_row, to_row)
  local track = song.tracks[track_index]
  local max_n, max_e = track.max_note_columns, track.max_effect_columns
  local auto = {}
  for _, span in ipairs(timeline.spans(tl, from_row, to_row)) do
    local ptrack = song:pattern(tl.slots[span.slot].pattern):track(track_index)
    for line_index = span.from_line, span.to_line do
      local row = span.first_row + line_index - span.from_line
      local line = ptrack:line(line_index)
      local ncols, ecols
      if not line.is_empty then
        for c = 1, max_n do
          local n = line:note_column(c)
          if not n.is_empty then
            ncols = ncols or {}
            ncols[c] = {
              n.note_value,
              n.instrument_value,
              n.volume_value,
              n.panning_value,
              n.delay_value,
              n.effect_number_value,
              n.effect_amount_value,
            }
          end
        end
        for c = 1, max_e do
          local e = line:effect_column(c)
          if not e.is_empty then
            ecols = ecols or {}
            ecols[c] = { e.number_value, e.amount_value }
          end
        end
      end
      content.notes[row] = ncols
      content.fx[row] = ecols
    end
    for _, automation in ipairs(ptrack.automation) do
      local d, p, name = automation_target(track, automation)
      if d and p then
        local key = envelopes.key(d, p)
        for _, point in ipairs(automation.points) do
          if point.time >= span.from_line and point.time < span.to_line + 1 then
            local env = auto[key]
            if not env then
              env = {
                device = d,
                param = p,
                playmode = automation.playmode,
                name = name,
                points = {},
              }
              auto[key] = env
            end
            env.points[#env.points + 1] =
              { span.first_row + point.time - span.from_line, point.value, point.scaling }
          end
        end
      end
    end
  end
  envelopes.copy_range(content.auto, auto, from_row, to_row)
end

local NOTE_FIELDS = {
  "note_value",
  "instrument_value",
  "volume_value",
  "panning_value",
  "delay_value",
  "effect_number_value",
  "effect_amount_value",
}

---@param ptrack renoise.PatternTrack
---@param track renoise.Track
---@param span TimelineSpan
---@param desired table<string, Envelope>
---@return integer ops
local function write_automation(ptrack, track, span, desired)
  local ops = 0
  local lo, hi = span.from_line, span.to_line + 1
  local offset = span.first_row - span.from_line
  local seen = {}
  ---@type renoise.DeviceParameter[]
  local emptied = {}
  for _, automation in ipairs(ptrack.automation) do
    local d, p = automation_target(track, automation)
    if d and p then
      local key = envelopes.key(d, p)
      seen[key] = true
      local have = {}
      for _, point in ipairs(automation.points) do
        if point.time >= lo and point.time < hi then
          have[#have + 1] = { point.time + offset, point.value, point.scaling }
        end
      end
      local want = {}
      local env = desired[key]
      if env then
        for _, pt in ipairs(env.points) do
          if pt[1] - offset >= lo and pt[1] - offset < hi then
            want[#want + 1] = pt
          end
        end
      end
      local same = envelopes.same_points(have, want)
      if not same then
        automation:clear_range(lo, hi)
        for _, pt in ipairs(want) do
          automation:add_point_at(pt[1] - offset, pt[2], pt[3] or 0)
        end
        if env and #want > 0 and automation.playmode ~= env.playmode then
          automation.playmode = env.playmode
        end
        ops = ops + 1 + #want
        if #automation.points == 0 then
          emptied[#emptied + 1] = automation.dest_parameter
        end
      end
    end
  end
  -- An envelope without points does nothing: remove it, after the loop over the list.
  for _, parameter in ipairs(emptied) do
    ptrack:delete_automation(parameter)
  end
  for key, env in pairs(desired) do
    if not seen[key] then
      local want = {}
      for _, pt in ipairs(env.points) do
        if pt[1] - offset >= lo and pt[1] - offset < hi then
          want[#want + 1] = pt
        end
      end
      local parameter = envelope_parameter(track, env)
      if #want > 0 and parameter then
        local automation = ptrack:create_automation(parameter)
        automation.playmode = env.playmode
        for _, pt in ipairs(want) do
          automation:add_point_at(pt[1] - offset, pt[2], pt[3] or 0)
        end
        ops = ops + 1 + #want
      end
    end
  end
  return ops
end

---Make the rows `from_row..to_row` of the track equal to `content`.
---@param song renoise.Song
---@param tl Timeline
---@param track_index integer
---@param content Content
---@param from_row integer
---@param to_row integer
---@param with_automation boolean? Also write the automation (default true).
---@return integer ops Number of changes made in the song.
function M.write(song, tl, track_index, content, from_row, to_row, with_automation)
  local track = song.tracks[track_index]
  local max_n, max_e = track.max_note_columns, track.max_effect_columns
  local ops = 0
  local used_n, used_e = 0, 0
  local use_vol, use_pan, use_dly, use_fx = false, false, false, false
  for _, span in ipairs(timeline.spans(tl, from_row, to_row)) do
    local ptrack = song:pattern(tl.slots[span.slot].pattern):track(track_index)
    for line_index = span.from_line, span.to_line do
      local row = span.first_row + line_index - span.from_line
      local ncols, ecols = content.notes[row], content.fx[row]
      local line = ptrack:line(line_index)
      if ncols or ecols or not line.is_empty then
        for c = 1, max_n do
          local want = ncols and ncols[c]
          local n = line:note_column(c)
          if want then
            used_n = math.max(used_n, c)
            use_vol = use_vol or want[3] ~= 255
            use_pan = use_pan or want[4] ~= 255
            use_dly = use_dly or want[5] ~= 0
            use_fx = use_fx or want[6] ~= 0 or want[7] ~= 0
            for f = 1, 7 do
              local field = NOTE_FIELDS[f]
              if n[field] ~= want[f] then
                n[field] = want[f]
                ops = ops + 1
              end
            end
          elseif not n.is_empty then
            n:clear()
            ops = ops + 1
          end
        end
        for c = 1, max_e do
          local want = ecols and ecols[c]
          local e = line:effect_column(c)
          if want then
            used_e = math.max(used_e, c)
            if e.number_value ~= want[1] then
              e.number_value = want[1]
              ops = ops + 1
            end
            if e.amount_value ~= want[2] then
              e.amount_value = want[2]
              ops = ops + 1
            end
          elseif not e.is_empty then
            e:clear()
            ops = ops + 1
          end
        end
      end
    end
    if with_automation ~= false then
      ops = ops + write_automation(ptrack, track, span, content.auto)
    end
  end
  -- Show what was written. Never hide a column: other patterns may use it.
  if used_n > track.visible_note_columns then
    track.visible_note_columns = used_n
  end
  if used_e > track.visible_effect_columns then
    track.visible_effect_columns = used_e
  end
  if use_vol and not track.volume_column_visible then
    track.volume_column_visible = true
  end
  if use_pan and not track.panning_column_visible then
    track.panning_column_visible = true
  end
  if use_dly and not track.delay_column_visible then
    track.delay_column_visible = true
  end
  if use_fx and not track.sample_effects_column_visible then
    track.sample_effects_column_visible = true
  end
  return ops
end

---Current value (0..1) of every automatable parameter of the track, by envelope key.
---The session takes this picture when it is armed, before any take moves a parameter.
---@param song renoise.Song
---@param track_index integer
---@return table<string, number>
function M.base_values(song, track_index)
  local out = {}
  for d, device in ipairs(song.tracks[track_index].devices) do
    for p, parameter in ipairs(device.parameters) do
      if parameter.is_automatable then
        local span = parameter.value_max - parameter.value_min
        out[envelopes.key(d, p)] = span > 0 and (parameter.value - parameter.value_min) / span or 0
      end
    end
  end
  return out
end

return M
