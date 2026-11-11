local t = require "tests.helper"
local takes = require "src.takes"

local OFF = takes.NOTE_OFF

local function note(n)
  return { n, 0, 255, 255, 0, 0, 0 }
end

---Build a take from { row, col, note } triples.
local function take(id, rows, list)
  local content = takes.new_content()
  for _, e in ipairs(list) do
    content.notes[e[1]] = content.notes[e[1]] or {}
    content.notes[e[1]][e[2]] = note(e[3])
  end
  return { id = id, rows = rows, content = content }
end

local function at(content, row, col)
  local cols = content.notes[row]
  return cols and cols[col] and cols[col][1] or nil
end

local function seg_text(segments)
  local out = {}
  for _, s in ipairs(segments) do
    out[#out + 1] = ("%d-%d=%d"):format(s.from, s.to, s.take)
  end
  return table.concat(out, " ")
end

-- Content basics.
local c = takes.new_content()
t.check(takes.is_empty(c), "new content is empty")
local a = take(1, 16, { { 1, 1, 48 }, { 5, 1, OFF }, { 9, 1, 50 }, { 9, 2, 53 } })
t.check(not takes.is_empty(a.content), "content with notes is not empty")
t.eq(takes.count_notes(a.content), 3, "count_notes ignores note-offs")
local nc, ec = takes.columns(a.content)
t.eq(nc, 2, "columns: note columns")
t.eq(ec, 0, "columns: effect columns")

-- has_events: more than note-offs.
t.check(takes.has_events(a.content), "has_events: notes")
t.check(
  not takes.has_events(take(30, 16, { { 3, 1, OFF } }).content),
  "has_events: only a note-off is not a take"
)
local only_volume = takes.new_content()
only_volume.notes[4] = { [1] = { 121, 255, 0x40, 255, 0, 0, 0 } }
t.check(takes.has_events(only_volume), "has_events: a volume value alone counts")
local only_fx = takes.new_content()
only_fx.fx[2] = { [1] = { 0x0A, 0x10 } }
t.check(takes.has_events(only_fx), "has_events: an effect command alone counts")
t.check(not takes.has_events(takes.new_content()), "has_events: empty content")

-- copy_rows replaces the range and copies the cells.
local dst = take(9, 16, { { 2, 1, 60 }, { 10, 1, 61 } }).content
takes.copy_rows(dst, a.content, 1, 8)
t.eq(at(dst, 1, 1), 48, "copy_rows: copies a note")
t.eq(at(dst, 2, 1), nil, "copy_rows: clears a row that the source does not have")
t.eq(at(dst, 10, 1), 61, "copy_rows: keeps rows outside the range")
dst.notes[1][1][1] = 99
t.eq(at(a.content, 1, 1), 48, "copy_rows: the copy does not share cells")
t.check(takes.equal(a.content, takes.solo(a, 16)), "solo: equal to the take")
t.check(not takes.equal(a.content, dst), "equal: different content")

-- Segments.
local segs = takes.assign({}, 1, 16, 1)
t.eq(seg_text(segs), "1-16=1", "assign: whole range")
segs = takes.assign(segs, 5, 8, 2)
t.eq(seg_text(segs), "1-4=1 5-8=2 9-16=1", "assign: split in the middle")
segs = takes.assign(segs, 9, 12, 2)
t.eq(seg_text(segs), "1-4=1 5-12=2 13-16=1", "assign: merge with the same take")
segs = takes.assign(segs, 3, 14, 1)
t.eq(seg_text(segs), "1-16=1", "assign: cover and merge back")
segs = takes.assign(segs, 8, 5, 3)
t.eq(seg_text(segs), "1-4=1 5-8=3 9-16=1", "assign: reversed range")
t.eq(takes.take_at(segs, 6), 3, "take_at: inside a segment")
t.eq(seg_text(takes.assign(segs, 1, 4, nil)), "5-8=3 9-16=1", "assign: nil removes rows")
t.eq(seg_text(takes.without_take(segs, 3)), "1-4=1 9-16=1", "without_take")
t.eq(takes.take_at(takes.without_take(segs, 3), 6), nil, "take_at: in a gap")

-- Render two takes with three segments.
local one = take(1, 16, { { 1, 1, 48 }, { 5, 1, 50 }, { 9, 1, 52 }, { 13, 1, 53 } })
local two = take(2, 16, { { 1, 1, 60 }, { 5, 1, 62 }, { 7, 1, OFF }, { 9, 1, 64 }, { 13, 1, 65 } })
local by_id = { one, two }
local comp = takes.new_comp()
comp.notes = takes.assign(takes.assign({}, 1, 16, 1), 5, 8, 2)
local content, healed = takes.render(by_id, comp, 16)
t.eq(at(content, 1, 1), 48, "render: row 1 from take 1")
t.eq(at(content, 5, 1), 62, "render: row 5 from take 2")
t.eq(at(content, 7, 1), OFF, "render: the note-off of take 2")
t.eq(at(content, 9, 1), 52, "render: row 9 from take 1")
t.eq(healed, 0, "render: a note at each cut needs no healing")

-- Healing: the outgoing take is sounding and the incoming take has no event at the cut.
local long = take(3, 16, { { 1, 1, 48 } })
local late = take(4, 16, { { 7, 1, 60 } })
comp = takes.new_comp()
comp.notes = takes.assign(takes.assign({}, 1, 16, 3), 5, 16, 4)
content, healed = takes.render({ [3] = long, [4] = late }, comp, 16)
t.eq(at(content, 5, 1), OFF, "heal: note-off at the cut")
t.eq(healed, 1, "heal: one note-off added")
t.eq(at(content, 7, 1), 60, "heal: the incoming note is kept")
t.eq(at(long.content, 5, 1), nil, "heal: the take itself is not changed")

-- Healing at the loop point: the last segment sounds into a different first segment.
local tail = take(5, 16, { { 15, 1, 70 } })
local head = take(6, 16, { { 3, 1, 72 }, { 6, 1, OFF } })
comp = takes.new_comp()
comp.notes = takes.assign(takes.assign({}, 1, 8, 6), 9, 16, 5)
content, healed = takes.render({ [5] = tail, [6] = head }, comp, 16)
t.eq(at(content, 1, 1), OFF, "heal: note-off at row 1 for a note that sounds over the loop point")
t.eq(healed, 1, "heal: only the loop point needs one")

-- No healing inside one take.
comp = takes.new_comp()
comp.notes = takes.assign({}, 1, 16, 5)
content, healed = takes.render({ [5] = tail }, comp, 16)
t.eq(healed, 0, "heal: one take alone is not changed")

-- The moves layer is independent of the notes layer.
local m1 = take(7, 16, { { 1, 1, 48 } })
m1.content.fx[2] = { { 0x0A, 0x10 } }
local m2 = take(8, 16, { { 1, 1, 60 } })
m2.content.fx[2] = { { 0x0A, 0x80 } }
comp = takes.new_comp()
comp.notes = takes.assign({}, 1, 16, 7)
comp.moves = takes.assign({}, 1, 16, 8)
content = takes.render({ [7] = m1, [8] = m2 }, comp, 16)
t.eq(at(content, 1, 1), 48, "layers: notes from take 7")
t.eq(content.fx[2][1][2], 0x80, "layers: moves from take 8")
t.eq(takes.count_moves(content), 1, "count_moves")

-- A note held over the loop end: its note-off is in the next pass.
local held = take(10, 64, { { 61, 1, 60 } })
local nxt = take(11, 64, { { 7, 1, OFF }, { 20, 1, 62 } })
t.eq(takes.adopt_orphan_offs(held, nxt), 1, "orphan note-off: adopted")
t.eq(at(held.content, 7, 1), OFF, "orphan note-off: copied into the earlier take")
local closed = take(12, 64, { { 50, 1, 60 }, { 60, 1, OFF } })
t.eq(takes.adopt_orphan_offs(closed, nxt), 0, "orphan note-off: not needed when the note ended")
local starts_with_note = take(13, 64, { { 3, 1, 62 } })
t.eq(
  takes.adopt_orphan_offs(take(14, 64, { { 61, 1, 60 } }), starts_with_note),
  0,
  "orphan note-off: the next pass starts with a note"
)

-- A parameter that one take moves is put back to its base value in content without that envelope.
local mover = take(20, 16, { { 1, 1, 48 } })
mover.content.auto["2:1"] =
  { device = 2, param = 1, playmode = 2, points = { { 1, 0.9, 0 }, { 9, 0.1, 0 } } }
local still = take(21, 16, { { 1, 1, 50 } })
local alone = takes.solo(still, 16)
t.eq(
  takes.add_base_points(alone, { mover, still }, { ["2:1"] = 0.5 }),
  1,
  "base point: added for a take without the envelope"
)
t.eq(alone.auto["2:1"].points[1][2], 0.5, "base point: the value from before the takes")
t.eq(still.content.auto["2:1"], nil, "base point: the take itself is not changed")
local with = takes.solo(mover, 16)
t.eq(
  takes.add_base_points(with, { mover, still }, { ["2:1"] = 0.5 }),
  0,
  "base point: not added when the content has the envelope"
)
t.eq(
  takes.add_base_points(takes.solo(still, 16), { mover, still }, nil),
  0,
  "base point: no base values, no point"
)

t.done()
