--[[
  The comping session of the current song. Thin: it connects Renoise (the
  transport, the pattern, a timer) to the pure modules.

  The pattern track is both the recording surface and the audition surface:
  * While you record, Renoise writes into the track. A timer follows the
    playhead and moves each finished part of the loop into a take.
  * When you do not record, the track holds the comp, or one whole take when
    you audition it. Renoise plays it with its own exact timing.

  `surface` is the content that the tool last wrote. Before the tool writes
  again it reads the track back. If the track differs, you edited it by hand,
  and that content becomes a new take. Nothing is lost.
]]

local codec = require "src.codec"
local passes = require "src.passes"
local pattern_io = require "src.pattern_io"
local takes = require "src.takes"
local timeline = require "src.timeline"

local Session = {}

Session.POLL_MS = 15
---A loop must last at least this long, so that each part can be read and
---cleared while the playhead is in another part.
Session.MIN_LOOP_SECONDS = 1.0
---Renoise writes a recorded note a little behind the playhead (about 45 ms in
---tests, which is the audio latency). A part of the loop is read only when the
---playhead is this far past it. The margin grows when a larger lag is seen.
Session.GUARD_SECONDS = 0.12
---The pattern matrix shows where the takes go. The slots of the armed track
---are orange, and red while you record. Renoise only draws a slot colour on a
---slot that holds notes, and the capture empties the slots as it goes. So while
---you record, the slots are also selected and deselected in turn: a selection
---shows on empty slots too, and every slot of the loop flashes.
Session.SLOT_ARMED = { 235, 150, 40 }
Session.SLOT_REC = { 225, 45, 40 }
Session.SLOT_REC_FLASH = { 255, 200, 190 }
Session.FLASH_TICKS = 18 -- timer ticks between two flash states, about a quarter second
Session.LOOP_CHECK_TICKS = 16

---@class RecordingState
---@field state PassState
---@field pending table<integer, { content: Content, overlapped: boolean }>
---@field last { take: Take, pass: integer }?
---@field best Take? The newest take of a complete pass, or the only take.
---@field count integer Takes made in this recording.
---@field max_lag integer Largest distance seen between the playhead and a recorded line, in rows.
---@field guard_limit integer The margin can never be larger than this.

---@class SessionState
---@field track integer
---@field tl Timeline
---@field takes Take[]
---@field comp Comp
---@field solo integer? Take that the track holds now, nil for the comp.
---@field surface Content What the tool last wrote to the track.
---@field base table<string, number>
---@field next_id integer
---@field link boolean
---@field armed boolean
---@field rec RecordingState?
---@field playhead integer? Timeline row of the playhead while the loop plays.
---@field stale boolean? The loop or a pattern length changed since the takes were recorded.
---@field last_ops integer? Changes made by the last write.
---@field slot_colors table<integer, any>? Matrix slot colours from before the session painted them.
---@field slot_painted table<integer, string>? What each slot shows now.
---@field flash integer? Counts timer ticks, for the flashing slots.
---@field slot_selected boolean? The session has selected the slots in the matrix.
---@field loop_ticks integer? Counts timer ticks, for the loop check.
---@field loop_seen string? The loop that the last check saw, when it is not the session's loop.
---@field loop_note string? What to do when the loop is not the session's loop.
---@field fresh boolean? Nothing was recorded or chosen yet: the session may move to another loop.
---@field track_ref renoise.Track? The armed track itself, to find its index again.

---@type table? The application module, set by `Session.init`.
local app
---@type SessionState?
local S
local loaded = false
---@type table? Scope that owns the poll timer while armed.
local scope
---@type table<function, boolean>
local listeners = {}

---@param a table The application module (`src/app.lua`).
function Session.init(a)
  app = a
end

---Call `fn(what)` after every change of the session. Returns a function that stops it.
---@param fn fun(what: string)
---@return fun()
function Session.listen(fn)
  listeners[fn] = true
  return function()
    listeners[fn] = nil
  end
end

---@param what string
local function notify(what)
  for fn in pairs(listeners) do
    fn(what)
  end
end

---@return table<integer, Take>
local function by_id()
  local map = {}
  if S then
    for _, take in ipairs(S.takes) do
      map[take.id] = take
    end
  end
  return map
end

---@param id integer
---@return Take?
function Session.take(id)
  return by_id()[id]
end

---The slots that the transport loops: the looped sequence range, or the selected pattern.
---@param song renoise.Song
---@return { seq: integer, pattern: integer, lines: integer }[]
local function loop_slots(song)
  local range = song.transport.loop_sequence_range
  local first, last = range[1], range[2]
  if first < 1 or last < first then
    first, last = song.selected_sequence_index, song.selected_sequence_index
  end
  local slots = {}
  for seq = first, last do
    local pattern = song.sequencer:pattern(seq)
    slots[#slots + 1] =
      { seq = seq, pattern = pattern, lines = song:pattern(pattern).number_of_lines }
  end
  return slots
end

---Find the armed track again. Its index changes when the user inserts, deletes
---or moves tracks, so the session keeps the track itself and looks it up.
---@param song renoise.Song
---@return boolean found
local function resolve_track(song)
  if not S then
    return false
  end
  local ref = S.track_ref
  local count = #song.tracks
  if not ref then
    return S.track <= count and song:track(S.track).type == renoise.Track.TRACK_TYPE_SEQUENCER
  end
  if S.track <= count and rawequal(song:track(S.track), ref) then
    return true
  end
  for index = 1, count do
    if rawequal(song:track(index), ref) then
      S.track = index
      return true
    end
  end
  return false
end

---@param song renoise.Song
---@return boolean
local function timeline_is_valid(song)
  if not S or not resolve_track(song) then
    return false
  end
  local length = #song.sequencer.pattern_sequence
  for _, slot in ipairs(S.tl.slots) do
    if slot.seq > length or song.sequencer:pattern(slot.seq) ~= slot.pattern then
      return false
    end
    if song:pattern(slot.pattern).number_of_lines ~= slot.lines then
      return false
    end
  end
  return true
end

---@param content Content
---@param overlapped boolean?
---@return Take
local function add_take(content, overlapped)
  assert(S)
  local take =
    { id = S.next_id, rows = S.tl.total, content = content, overlapped = overlapped or nil }
  S.next_id = S.next_id + 1
  S.takes[#S.takes + 1] = take
  return take
end

---@param take Take
local function comp_whole(take)
  assert(S)
  S.comp.notes = takes.assign({}, 1, S.tl.total, take.id)
  S.comp.moves = takes.assign({}, 1, S.tl.total, take.id)
end

---Read the track back. If it is not what the tool wrote, keep it as a new take.
---@param song renoise.Song
---@return boolean changed
local function sync_check(song)
  assert(S)
  local now = takes.new_content()
  pattern_io.read(song, S.tl, S.track, now, 1, S.tl.total)
  if takes.equal(now, S.surface) then
    return false
  end
  S.surface = now
  S.solo = nil
  S.fresh = false
  if takes.is_empty(now) then
    S.comp = takes.new_comp()
  else
    comp_whole(add_take(now))
  end
  return true
end

---The content that the track should hold now: the comp, or the auditioned take.
---@return Content
local function desired_content()
  assert(S)
  local map = by_id()
  local desired
  local solo = S.solo and map[S.solo]
  if solo then
    desired = takes.solo(solo, S.tl.total)
  else
    S.solo = nil
    desired = takes.render(map, S.comp, S.tl.total, S.base)
  end
  takes.add_base_points(desired, S.takes, S.base)
  return desired
end

---Write the comp, or the auditioned take, into the track.
---@param song renoise.Song
local function show(song)
  assert(S)
  local desired = desired_content()
  pattern_io.prune(song, S.track, desired)
  song:describe_batch_undo("Takes: audition", 1500)
  S.last_ops = pattern_io.write(song, S.tl, S.track, desired, 1, S.tl.total)
  S.surface = desired
end

-- Recording ------------------------------------------------------------------

---@param song renoise.Song
---@param actions PassAction[]
local function run(song, actions)
  local rec = S and S.rec
  if not S or not rec then
    return
  end
  for _, a in ipairs(actions) do
    if a.kind == "harvest" then
      local pend = rec.pending[a.pass] or { content = takes.new_content(), overlapped = false }
      rec.pending[a.pass] = pend
      local part = takes.new_content()
      pattern_io.read(song, S.tl, S.track, part, a.from, a.to)
      if not takes.is_empty(part) then
        takes.copy_rows(pend.content, part, a.from, a.to)
        pattern_io.write(song, S.tl, S.track, takes.new_content(), a.from, a.to)
        pend.overlapped = pend.overlapped or a.overlapped or false
      end
    else
      local pend = rec.pending[a.pass]
      rec.pending[a.pass] = nil
      if pend and not takes.is_empty(pend.content) then
        local prev = rec.last
        local take = { id = 0, rows = S.tl.total, content = pend.content }
        if prev and prev.pass == a.pass - 1 then
          takes.adopt_orphan_offs(prev.take, take)
        end
        -- A pass that only holds the note-offs of the pass before is not a take.
        if takes.has_events(pend.content) then
          take = add_take(pend.content, pend.overlapped)
          S.fresh = false
          rec.last = { take = take, pass = a.pass }
          if a.complete or not rec.best then
            rec.best = take
          end
          rec.count = rec.count + 1
          notify "take"
        end
      end
    end
  end
end

---@param song renoise.Song
---@param row integer
local function begin_recording(song, row)
  assert(S)
  sync_check(song)
  song:describe_undo "Takes: start recording"
  local empty = takes.new_content()
  pattern_io.write(song, S.tl, S.track, empty, 1, S.tl.total)
  S.surface = empty
  local chunks = timeline.chunks(S.tl)
  local shortest = S.tl.total
  for _, c in ipairs(chunks) do
    shortest = math.min(shortest, c.to - c.from + 1)
  end
  local transport = song.transport
  local lines_per_second = transport.bpm * transport.lpb / 60
  local guard = math.ceil(lines_per_second * Session.GUARD_SECONDS) + 1
  if transport.record_quantize_enabled then
    guard = guard + transport.record_quantize_lines
  end
  local limit = math.max(1, math.floor(shortest / 2))
  S.rec = {
    state = passes.new(S.tl.total, chunks, math.max(1, math.min(guard, limit)), row),
    pending = {},
    count = 0,
    max_lag = 0,
    guard_limit = limit,
  }
  notify "recording"
end

---Renoise calls this for every line that the user records or types. It
---measures how far behind the playhead the recorder writes, and widens the
---margin of the capture when needed.
---@param pos PatternLinePosition
local function on_line_edited(pos)
  local rec = S and S.rec
  if not S or not rec or pos.track ~= S.track then
    return
  end
  for _, slot in ipairs(S.tl.slots) do
    if slot.pattern == pos.pattern then
      local song = renoise.song()
      local playing = song and song.transport.playback_pos
      local now = playing and timeline.row_of(S.tl, playing.sequence, playing.line)
      if now then
        local lag = (now - (slot.first + pos.line - 1)) % S.tl.total
        if lag < S.tl.total / 2 and lag > rec.max_lag then
          rec.max_lag = lag
          rec.state.guard = math.max(rec.state.guard, math.min(2 * lag + 1, rec.guard_limit))
        end
      end
      return
    end
  end
end

---@param song renoise.Song
local function end_recording(song)
  assert(S and S.rec)
  -- If the patterns changed under the recording, the pass in progress cannot be read.
  local valid = timeline_is_valid(song)
  if valid then
    run(song, passes.finish(S.rec.state))
  end
  -- After a recording you hear the newest complete pass. The pass that was cut
  -- off by the stop is kept as a take, but it is rarely the one you want.
  local best = S.rec.best
  S.rec = nil
  if best then
    if #S.comp.notes == 0 and #S.comp.moves == 0 then
      comp_whole(best)
      S.solo = nil
    else
      S.solo = best.id
    end
  end
  if valid then
    show(song)
  end
  notify "stopped"
end

---@param color any
---@return boolean ours True for a colour that this tool paints.
local function is_session_color(color)
  for _, own in ipairs { Session.SLOT_ARMED, Session.SLOT_REC, Session.SLOT_REC_FLASH } do
    if color[1] == own[1] and color[2] == own[2] and color[3] == own[3] then
      return true
    end
  end
  return false
end

---Select or deselect the matrix slots of the armed track.
---@param song renoise.Song
---@param on boolean
local function select_slots(song, on)
  if not S or (S.slot_selected or false) == on then
    return
  end
  S.slot_selected = on
  local track = S.track
  for _, slot in ipairs(S.tl.slots) do
    pcall(function() -- the sequence may have changed
      song.sequencer:set_track_sequence_slot_is_selected(track, slot.seq, on)
    end)
  end
end

---Colour the pattern matrix slots of the armed track, and flash them while recording.
---@param song renoise.Song
local function paint_slots(song)
  if not S then
    return
  end
  if not S.slot_colors then
    S.slot_colors, S.slot_painted = {}, {}
    for i, slot in ipairs(S.tl.slots) do
      local color = song:pattern(slot.pattern):track(S.track).color
      -- A colour of this tool can be left over after an undo. It is not the slot's own colour.
      if color and is_session_color(color) then
        color = nil
      end
      S.slot_colors[i] = color or false
    end
  end
  S.flash = (S.flash or 0) + 1
  local lit = math.floor(S.flash / Session.FLASH_TICKS) % 2 == 1
  for i, slot in ipairs(S.tl.slots) do
    local color = Session.SLOT_ARMED
    if S.rec then
      color = lit and Session.SLOT_REC_FLASH or Session.SLOT_REC -- every slot flashes
    end
    local key = color[1] .. "," .. color[2] .. "," .. color[3]
    if S.slot_painted[i] ~= key then
      song:pattern(slot.pattern):track(S.track).color = color
      S.slot_painted[i] = key
    end
  end
  select_slots(song, S.rec ~= nil and lit)
end

---Give the matrix slots their own colours back.
---@param song renoise.Song
local function restore_slots(song)
  select_slots(song, false)
  local colors = S and S.slot_colors
  if not S or not colors then
    return
  end
  local track, slots = S.track, S.tl.slots
  S.slot_colors, S.slot_painted = nil, nil
  for i, slot in ipairs(slots) do
    local original = colors[i] or nil
    pcall(function() -- the pattern or the track may be gone
      song:pattern(slot.pattern):track(track).color = original
    end)
  end
  -- A cloned pattern, a sorted sequence or an undo can leave a colour of this
  -- tool in another pattern. Clear those too.
  pcall(function()
    for index = 1, #song.patterns do
      local ptrack = song:pattern(index):track(track)
      local color = ptrack.color
      if color and is_session_color(color) then
        ptrack.color = nil
      end
    end
  end)
end

---@param slots { seq: integer, pattern: integer, lines: integer }[]
---@return string
local function slots_key(slots)
  local parts = {}
  for i, slot in ipairs(slots) do
    parts[i] = slot.seq .. ":" .. slot.pattern .. ":" .. slot.lines
  end
  return table.concat(parts, " ")
end

---The user changed the loop while the session is armed. A session without
---takes moves to the new loop. A session with takes stays, and says so.
---@param song renoise.Song
local function follow_loop(song)
  if not S then
    return
  end
  local key = slots_key(loop_slots(song))
  if key == slots_key(S.tl.slots) then
    S.loop_seen, S.loop_note = nil, nil
    return
  end
  if not S.fresh then
    S.loop_note = "The loop changed: set it back, or press New session"
    return
  end
  -- Wait until the loop is the same in two checks, so a drag over the sequence does not arm ten times.
  if S.loop_seen ~= key then
    S.loop_seen = key
    return
  end
  if song.selected_track_index ~= S.track then
    return
  end
  local link = S.link
  local ok, _, code = Session.arm()
  if ok and S then
    S.link = link
  elseif S then
    S.loop_note = code == "repeated" and "The new loop uses a pattern twice: press Done, then Arm"
      or "The new loop cannot be used: press Done, then Arm"
  end
end

local function tick()
  local song = renoise.song()
  if not song or not S or not S.armed then
    return
  end
  local transport = song.transport
  local row = nil
  if transport.playing then
    local pos = transport.playback_pos
    row = timeline.row_of(S.tl, pos.sequence, pos.line)
  end
  S.playhead = row
  local valid = timeline_is_valid(song)
  local want = row ~= nil
    and transport.edit_mode
    and transport.follow_player
    and song.selected_track_index == S.track
    and not (#S.tl.slots > 1 and transport.loop_pattern)
    and valid
  if S.rec and not want then
    end_recording(song)
  elseif not S.rec and want and row then
    begin_recording(song, row)
  end
  if S.rec and row then
    run(song, passes.step(S.rec.state, row))
  end
  if valid then
    paint_slots(song)
  end
  -- The loop may change while the session is armed: look a few times a second.
  S.loop_ticks = (S.loop_ticks or 0) + 1
  if not S.rec and S.loop_ticks % Session.LOOP_CHECK_TICKS == 0 then
    follow_loop(song)
  end
end

---What the session is doing, and what is missing before a recording starts.
---The third value is a note about a loop that changed while the session is armed.
---@return "none"|"stale"|"idle"|"recording"|"waiting" state, string[] missing, string? note
function Session.readiness()
  local song = renoise.song()
  if not S or not song then
    return "none", {}
  end
  if S.stale then
    return "stale", {}
  end
  if not S.armed then
    return "idle", {}
  end
  if S.rec then
    return "recording", {}
  end
  local transport = song.transport
  local missing = {}
  if song.selected_track_index ~= S.track then
    missing[#missing + 1] = ("put the cursor in track %02d"):format(S.track)
  end
  if not transport.edit_mode then
    missing[#missing + 1] = "turn edit mode on"
  end
  if not transport.follow_player then
    missing[#missing + 1] = "turn pattern follow on"
  end
  if #S.tl.slots > 1 and transport.loop_pattern then
    missing[#missing + 1] = "turn the pattern loop off"
  end
  if not transport.playing then
    missing[#missing + 1] = "press play"
  elseif not S.playhead then
    missing[#missing + 1] = "play inside the loop"
  end
  return "waiting", missing, S.loop_note
end

-- Public actions ---------------------------------------------------------------

---@return SessionState?
function Session.get()
  Session.load()
  return S
end

---Bind the session to the selected track and to the loop, and start to listen.
---@param opts { make_unique: boolean?, replace: boolean? }?
---@return boolean ok, string? message, string? code
function Session.arm(opts)
  assert(app, "Session.init was not called")
  opts = opts or {}
  local song = renoise.song()
  if not song then
    return false, "There is no song.", "song"
  end
  Session.load()
  local track_index = song.selected_track_index
  if song.tracks[track_index].type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
    return false,
      "Select a normal track first. Group, send and master tracks hold no notes.",
      "track"
  end
  if song.transport.loop_block_enabled then
    return false,
      "Turn the block loop off first. Takes need a pattern loop or a sequence loop.",
      "block"
  end
  local slots = loop_slots(song)
  if S and not opts.replace and not S.fresh then
    resolve_track(song)
    if S.track ~= track_index or slots_key(slots) ~= slots_key(S.tl.slots) then
      return false,
        "This song has takes for another track or loop. Start a new session to replace them.",
        "other"
    end
  end
  local seen, repeated = {}, false
  for _, slot in ipairs(slots) do
    repeated = repeated or seen[slot.pattern] ~= nil
    seen[slot.pattern] = true
  end
  if repeated then
    if not opts.make_unique then
      return false,
        "A pattern is used twice in the loop. Each slot needs its own pattern.",
        "repeated"
    end
    song:describe_undo "Takes: make the looped patterns unique"
    song.sequencer:make_range_unique(slots[1].seq, slots[#slots].seq)
    slots = loop_slots(song)
  end
  for _, slot in ipairs(slots) do
    if song:pattern(slot.pattern):track(track_index).is_alias then
      return false, "This track is an alias in a looped pattern. Remove the alias first.", "alias"
    end
  end
  local tl = timeline.new(slots)
  local seconds = tl.total / (song.transport.bpm * song.transport.lpb / 60)
  if seconds < Session.MIN_LOOP_SECONDS then
    return false,
      ("The loop lasts %.2f seconds at this tempo. Takes need at least %.0f second."):format(
        seconds,
        Session.MIN_LOOP_SECONDS
      ),
      "short"
  end
  if S and (S.track ~= track_index or not timeline.same(S.tl, tl)) then
    restore_slots(song) -- the old loop gets its matrix colours back
    S = nil
  end
  if not S then
    S = {
      track = track_index,
      tl = tl,
      takes = {},
      comp = takes.new_comp(),
      solo = nil,
      surface = takes.new_content(),
      base = pattern_io.base_values(song, track_index),
      next_id = 1,
      link = true,
      armed = false,
      fresh = true,
    }
    local existing = takes.new_content()
    pattern_io.read(song, tl, track_index, existing, 1, tl.total)
    S.surface = existing
    if not takes.is_empty(existing) then
      comp_whole(add_take(existing))
    end
  else
    S.stale = nil
    sync_check(song)
  end
  -- A pattern loop wins over a sequence loop in Renoise: the playhead would
  -- never leave the first pattern. So set the loop mode that the session needs.
  if #slots > 1 then
    song.transport.loop_pattern = false
  elseif song.transport.loop_sequence_range[1] == 0 then
    song.transport.loop_pattern = true
  end
  -- A live recording follows the playhead. Without pattern follow, Renoise
  -- writes at the edit cursor, and no pass would be captured.
  song.transport.follow_player = true
  S.track_ref = song:track(track_index)
  S.armed = true
  if scope then
    scope.release()
  end
  scope = app.reg.scope()
  local edited = app.safe(on_line_edited)
  for _, slot in ipairs(tl.slots) do
    local pattern = song:pattern(slot.pattern)
    if not pattern:has_line_edited_notifier(edited) then
      pattern:add_line_edited_notifier(edited)
      scope.add(function()
        pattern:remove_line_edited_notifier(edited)
      end)
    end
  end
  scope.timer(
    app.safe(tick, function()
      Session.disarm()
    end),
    Session.POLL_MS
  )
  notify "armed"
  return true, nil, nil
end

---Stop to listen. The track gets the comp. The takes stay in the song.
function Session.disarm()
  local song = renoise.song()
  if scope then
    scope.release()
    scope = nil
  end
  if not S then
    return
  end
  if song and S.armed then
    -- Whatever fails here, the session must end up disarmed and unpainted.
    local ok, err = pcall(function()
      if S.rec then
        end_recording(song)
      end
      if timeline_is_valid(song) then
        sync_check(song)
        S.solo = nil
        show(song)
      end
    end)
    if not ok and app then
      app.log("the session could not write the comp while it stopped: " .. tostring(err))
    end
  end
  if song then
    pcall(restore_slots, song)
  end
  S.armed = false
  S.rec = nil
  S.playhead = nil
  Session.save()
  notify "disarmed"
end

---Give rows of the comp to a take.
---@param layer Layer? Both layers when nil.
---@param from integer
---@param to integer
---@param take_id integer? nil removes the rows from the comp.
function Session.assign(layer, from, to, take_id)
  local song = renoise.song()
  if not song or not S or S.rec or not timeline_is_valid(song) then
    return
  end
  sync_check(song)
  from = math.max(1, math.min(from, S.tl.total))
  to = math.max(1, math.min(to, S.tl.total))
  if layer == nil or layer == "notes" then
    S.comp.notes = takes.assign(S.comp.notes, from, to, take_id)
  end
  if layer == nil or layer == "moves" then
    S.comp.moves = takes.assign(S.comp.moves, from, to, take_id)
  end
  S.solo = nil
  S.fresh = false
  show(song)
  notify "comp"
end

---Audition one whole take, or go back to the comp with nil.
---@param take_id integer?
function Session.set_solo(take_id)
  local song = renoise.song()
  if not song or not S or S.rec or not timeline_is_valid(song) then
    return
  end
  sync_check(song)
  S.solo = take_id
  S.fresh = false
  show(song)
  notify "solo"
end

---@param take_id integer
function Session.delete_take(take_id)
  local song = renoise.song()
  if not song or not S or S.rec then
    return
  end
  local valid = timeline_is_valid(song)
  if valid then
    sync_check(song)
  end
  S.fresh = false
  for i, take in ipairs(S.takes) do
    if take.id == take_id then
      table.remove(S.takes, i)
      break
    end
  end
  S.comp.notes = takes.without_take(S.comp.notes, take_id)
  S.comp.moves = takes.without_take(S.comp.moves, take_id)
  if S.solo == take_id then
    S.solo = nil
  end
  if valid then
    show(song)
  end
  notify "takes"
end

---@param link boolean
function Session.set_link(link)
  if S then
    S.link = link
    notify "link"
  end
end

---Forget all takes of this song. The track keeps what it holds now.
function Session.reset()
  -- A recording in progress has emptied the track. Stop it first, so the
  -- track gets the comp back before the takes go away.
  if S and S.armed then
    Session.disarm()
  end
  if scope then
    scope.release()
    scope = nil
  end
  local song = renoise.song()
  if song then
    restore_slots(song)
    song.tool_data = nil
  end
  S = nil
  notify "reset"
end

-- Data for the view -------------------------------------------------------------

---The comp as content, without the audition.
---@return Content?
function Session.comp_content()
  if not S then
    return nil
  end
  return (takes.render(by_id(), S.comp, S.tl.total, S.base))
end

---What the pass in progress holds so far: the parts already read, and the
---part that is still in the pattern.
---@return Content?
function Session.live_content()
  local song = renoise.song()
  local rec = S and S.rec
  if not song or not S or not rec then
    return nil
  end
  local out = takes.new_content()
  local pend = rec.pending[passes.current_pass(rec.state)]
  if pend then
    takes.copy_rows(out, pend.content, 1, S.tl.total)
  end
  local live = takes.new_content()
  pattern_io.read(song, S.tl, S.track, live, 1, S.tl.total)
  for row, cols in pairs(live.notes) do
    out.notes[row] = cols
  end
  for row, cols in pairs(live.fx) do
    out.fx[row] = cols
  end
  for key, env in pairs(live.auto) do
    local have = out.auto[key]
    if not have then
      out.auto[key] = env
    else
      for _, point in ipairs(env.points) do
        have.points[#have.points + 1] = point
      end
      table.sort(have.points, function(a, b)
        return a[1] < b[1]
      end)
    end
  end
  return out
end

-- Persistence ------------------------------------------------------------------

---Write the session into the song. Renoise saves it with the song file.
function Session.save()
  local song = renoise.song()
  if not song or not S then
    return
  end
  -- A recording has emptied the track. End it, so the file holds the comp
  -- and not a cleared track. The timer starts the recording again.
  if S.rec then
    pcall(end_recording, song)
  end
  -- The slot colours of an armed session must not end up in the song file.
  -- The timer paints them again after the save.
  restore_slots(song)
  local slots = {}
  for i, slot in ipairs(S.tl.slots) do
    slots[i] = { seq = slot.seq, pattern = slot.pattern, lines = slot.lines }
  end
  song.tool_data = codec.encode {
    track = S.track,
    next_id = S.next_id,
    link = S.link,
    solo = S.solo,
    slots = slots,
    base = S.base,
    takes = S.takes,
    comp = S.comp,
  }
end

---Read the session of the current song, once for each song.
function Session.load()
  if loaded then
    return
  end
  local song = renoise.song()
  if not song then
    return
  end
  loaded = true
  S = nil
  local data, err = codec.decode(song.tool_data)
  if not data then
    if err ~= "no data" and app then
      app.log("takes in this song could not be read: " .. tostring(err))
    end
    return
  end
  local tl = timeline.new(data.slots)
  S = {
    track = data.track,
    tl = tl,
    takes = data.takes,
    comp = data.comp,
    solo = data.solo,
    surface = takes.new_content(),
    base = data.base,
    next_id = data.next_id,
    link = data.link,
    armed = false,
  }
  if S.track <= #song.tracks then
    S.track_ref = song:track(S.track)
  end
  S.surface = desired_content()
  S.stale = not timeline_is_valid(song) or nil
  if not S.stale then
    pattern_io.prune(song, S.track, S.surface)
  end
end

---The song is going away: drop the state without touching the song.
function Session.release()
  if scope then
    scope.release()
    scope = nil
  end
  S = nil
  loaded = false
  notify "released"
end

---The tool stops (reload or unload): keep the takes in the song.
function Session.shutdown()
  if S and S.armed then
    Session.disarm()
  else
    Session.save()
  end
  if scope then
    scope.release()
    scope = nil
  end
  S = nil
  loaded = false
  listeners = {}
end

---One screen of text about the session, for `just eval`.
---@return string
function Session.summary()
  Session.load()
  if not S then
    return "no session"
  end
  local out = {}
  local slots = {}
  for _, slot in ipairs(S.tl.slots) do
    slots[#slots + 1] = ("seq %d pattern %d (%d lines)"):format(slot.seq, slot.pattern, slot.lines)
  end
  out[#out + 1] = ("track %d, %d rows: %s"):format(S.track, S.tl.total, table.concat(slots, ", "))
  if S.rec then
    out[#out + 1] = ("recording: margin %d rows, largest lag seen %d rows"):format(
      S.rec.state.guard,
      S.rec.max_lag
    )
  end
  out[#out + 1] = ("armed=%s recording=%s solo=%s stale=%s playhead=%s last_ops=%s"):format(
    tostring(S.armed),
    tostring(S.rec ~= nil),
    tostring(S.solo),
    tostring(S.stale or false),
    tostring(S.playhead),
    tostring(S.last_ops)
  )
  for _, take in ipairs(S.takes) do
    local rows = {}
    for row in pairs(take.content.notes) do
      rows[#rows + 1] = row
    end
    table.sort(rows)
    local cells = {}
    for _, row in ipairs(rows) do
      local cols = {}
      for col, cell in pairs(take.content.notes[row]) do
        cols[#cols + 1] = ("%d:%d"):format(col, cell[1])
      end
      table.sort(cols)
      cells[#cells + 1] = ("%d[%s]"):format(row, table.concat(cols, ","))
    end
    out[#out + 1] = ("take %d: %d notes, %d moves%s  %s"):format(
      take.id,
      takes.count_notes(take.content),
      takes.count_moves(take.content),
      take.overlapped and " (overlapped)" or "",
      table.concat(cells, " ")
    )
  end
  for _, layer in ipairs { "notes", "moves" } do
    local segs = {}
    for _, s in ipairs(S.comp[layer]) do
      segs[#segs + 1] = ("%d-%d=take %d"):format(s.from, s.to, s.take)
    end
    out[#out + 1] = ("comp %s: %s"):format(
      layer,
      #segs > 0 and table.concat(segs, ", ") or "(empty)"
    )
  end
  return table.concat(out, "\n")
end

return Session
