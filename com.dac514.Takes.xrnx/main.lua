--[[
  Entry point. Renoise runs this file once every time the tool is (re)loaded.

  Keep it thin and idempotent:
  * The tool has no preferences yet. If it gets some, create the document
    here, once: a dev-bridge soft reload re-requires `src/` without re-running
    this file, so `src/` must only read `renoise.tool().preferences`.
  * Behaviour lives in `src/app.lua` and is started with `APP.start()`.
  * The dev bridge in `dev/` is loaded only when present. `just package` strips
    `dev/`, so released builds never reference it.
]]

local bundle_path = renoise.tool().bundle_path
local DEV = io.exists(bundle_path .. "dev/bridge.lua")

-- Renoise resolves relative `require` paths only while loading main.lua (its
-- working directory is elsewhere during callbacks). Make `require "src.x"`
-- work everywhere, including the dev bridge's soft reload.
package.path = bundle_path .. "?.lua;" .. package.path

-- Renoise can reload this tool by itself whenever its window regains focus after
-- a file changed (`_AUTO_RELOAD_DEBUG = true`). It is off here because opening a
-- dialog counts as "regaining focus", which makes `just reload-soft` unreliable;
-- `just reload` does a full reload through OSC instead. Enable it if you edit in
-- an external editor and like alt-tab reloads.
_AUTO_RELOAD_DEBUG = false

-- The application module is a deliberate global so the dev bridge can reach it
-- (`APP.dialogs`, `APP.stop()`, `APP.start()`).
APP = require "src.app"
APP.start()

if DEV then
  require("dev.bridge").start()
end
