-- Run with `just test` (or `luajit tests/labels_test.lua` from the repo root).
local t = require "tests.helper"
local labels = require "src.labels"

t.eq(labels.note(0), "C-0", "note: lowest")
t.eq(labels.note(48), "C-4", "note: C-4")
t.eq(labels.note(49), "C#4", "note: sharp")
t.eq(labels.note(119), "B-9", "note: highest")
t.eq(labels.note(120), "OFF", "note: note-off")
t.eq(labels.note(121), "---", "note: empty")

t.eq(labels.line(1), "00", "line: the first line is 00")
t.eq(labels.line(17), "10", "line: hexadecimal")
t.eq(labels.line(256), "FF", "line: FF")

t.eq(
  labels.note_cell { 48, 1, 0x40, 255, 0, 0, 0 },
  "C-4 01 40 .. ..",
  "note_cell: note, instrument, volume"
)
t.eq(
  labels.note_cell { 120, 255, 255, 255, 0x5A, 0, 0 },
  "OFF .. .. .. 5A",
  "note_cell: note-off with delay"
)
t.eq(
  labels.note_cell { 60, 0, 255, 255, 0, 0x0A, 0x20 },
  "C-5 00 .. .. .. 0A20",
  "note_cell: sample effect"
)

t.eq(labels.lane(nil), "COMP", "lane: comp")
t.eq(labels.lane(3), "TAKE 3", "lane: take")

t.eq(
  labels.readout {
    row = 5,
    line = 5,
    lane = "COMP",
    notes = { { 48, 0, 255, 255, 0, 0, 0 } },
    notes_from = 2,
  },
  "Line 04    COMP    notes (take 2): C-4 00 .. .. ..    moves: -",
  "readout: a note from take 2"
)
t.eq(
  labels.readout { row = 1, line = 1, lane = "TAKE 1", moves = { "Gain 0.50" } },
  "Line 00    TAKE 1    notes: -    moves: Gain 0.50",
  "readout: a parameter move"
)

t.done()
