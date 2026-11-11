--[[
  Application module. Owns everything the tool registers with Renoise (menu
  entries, key bindings, notifiers, timers, dialogs) so that it can be started
  and stopped cleanly. That is what makes the dev bridge's soft reload safe:
  `APP.stop()` on the old module, re-require `src/`, `APP.start()` on the new one.

  Rules:
  * Register only through `App.reg.*` and `App.register_dialog`.
  * No side effects at module level; do them in `App.start()`.
  * `App.start()` can run while Renoise is still starting, when reading
    `renoise.app().theme` raises an error. Register `renoise.app()`
    observables when a dialog first opens instead.
  * Wrap callbacks that Renoise invokes with `App.guard` so errors reach the
    dev log. Use `App.safe` for timers: it logs and does not raise again.
  * Things that live shorter than the tool (a dialog, a session) register
    through `App.reg.scope()` and release the scope when they end.
  * Inside song list notifiers, read dependents through `App.defer`.
]]

local App = {}

---The comping session module (`src/session.lua`), set by `App.start`.
---@type table?
App.session = nil

---Handlers of the open lanes view, so that `just eval` can drive it without a mouse.
---@type table?
App.ui = nil

App.name = "Takes"
App.menu_entry = "Main Menu:Tools:" .. App.name .. "..."
App.keybinding = "Global:Tools:Show " .. App.name

---@class AppDialogEntry
---@field dialog renoise.Dialog
---@field vb renoise.ViewBuilder
---@field root renoise.Views.View
---@field scope AppScope? Released when the dialog closes.

---Registered dialogs by name. Read by the dev bridge's `views` command.
---@type table<string, AppDialogEntry>
App.dialogs = {}

---Log sink. The dev bridge replaces it to capture messages into its ring buffer.
---@type fun(kind: string, text: string)
App.log_sink = function(kind, text)
  print(("[%s] %s"):format(kind, text))
end

---Replace the log sink (used by the dev bridge).
---@param sink fun(kind: string, text: string)
function App.set_log_sink(sink)
  App.log_sink = sink
end

---@param text string
function App.log(text)
  App.log_sink("app", text)
end

---Wrap a callback so that errors are logged before being re-raised.
---@generic F : function
---@param fn F
---@return F
function App.guard(fn)
  return function(...)
    local n = select("#", ...)
    local args = { ... }
    local results = {
      xpcall(function()
        return fn(unpack(args, 1, n))
      end, function(err)
        return debug.traceback(tostring(err), 2)
      end),
    }
    if not results[1] then
      local message = results[2] and tostring(results[2]) or "unknown error"
      App.log_sink("error", message)
      error(message, 0)
    end
    return unpack(results, 2)
  end
end

---Wrap a callback so that errors are logged and not raised again. Use it for
---timers: a timer that raises on every tick would open an error popup each time.
---@param fn function
---@param on_error fun()? Called once, after the first error.
---@return function
function App.safe(fn, on_error)
  local failed = false
  return function(...)
    local n = select("#", ...)
    local args = { ... }
    local ok, err = xpcall(function()
      return fn(unpack(args, 1, n))
    end, function(e)
      return debug.traceback(tostring(e), 2)
    end)
    if not ok and not failed then
      failed = true
      App.log_sink("error", tostring(err))
      if on_error then
        local handled, why = pcall(on_error)
        if not handled then
          App.log_sink("error", "the error handler failed too: " .. tostring(why))
        end
      end
    end
  end
end

-- Registration ---------------------------------------------------------------

---Registration helpers. Everything registered here is undone by `App.stop()`.
local reg = {
  ---@type string[]
  menus = {},
  ---@type string[]
  keys = {},
  ---@type { observable: renoise.Document.Observable, fn: function }[]
  notifiers = {},
  ---@type function[]
  timers = {},
  ---@type table<AppScope, boolean>
  scopes = {},
}
App.reg = reg

---@param entry ToolMenuEntry
function reg.menu(entry)
  local tool = renoise.tool()
  if tool:has_menu_entry(entry.name) then
    tool:remove_menu_entry(entry.name)
  end
  tool:add_menu_entry(entry)
  table.insert(reg.menus, entry.name)
end

---@param binding ToolKeybindingEntry
function reg.key(binding)
  local tool = renoise.tool()
  if tool:has_keybinding(binding.name) then
    tool:remove_keybinding(binding.name)
  end
  tool:add_keybinding(binding)
  table.insert(reg.keys, binding.name)
end

---@param observable renoise.Document.Observable
---@param fn function
function reg.notifier(observable, fn)
  if observable:has_notifier(fn) then
    return -- already registered and tracked; safe to call again on refresh
  end
  observable:add_notifier(fn)
  table.insert(reg.notifiers, { observable = observable, fn = fn })
end

---@param fn function
---@param interval_ms integer
function reg.timer(fn, interval_ms)
  local tool = renoise.tool()
  if tool:has_timer(fn) then
    tool:remove_timer(fn)
  end
  tool:add_timer(fn, interval_ms)
  table.insert(reg.timers, fn)
end

---@class AppScope
---@field notifier fun(observable: renoise.Document.Observable, fn: function)
---@field timer fun(fn: function, interval_ms: integer)
---@field add fun(undo: fun()) Register any other cleanup, for example a pattern line notifier.
---@field release fun() Undo everything. Safe to call twice.

---A group of registrations that ends before the tool does: a dialog or a
---session. `App.stop()` releases every scope that is still open.
---@return AppScope
function reg.scope()
  ---@type fun()[]
  local undo = {}
  ---@type AppScope
  local scope
  scope = {
    notifier = function(observable, fn)
      observable:add_notifier(fn)
      undo[#undo + 1] = function()
        if observable:has_notifier(fn) then
          observable:remove_notifier(fn)
        end
      end
    end,
    timer = function(fn, interval_ms)
      local tool = renoise.tool()
      tool:add_timer(fn, interval_ms)
      undo[#undo + 1] = function()
        if tool:has_timer(fn) then
          tool:remove_timer(fn)
        end
      end
    end,
    add = function(fn)
      undo[#undo + 1] = fn
    end,
    release = function()
      local list = undo
      undo = {}
      for i = #list, 1, -1 do
        pcall(list[i]) -- the observable may belong to a song that no longer exists
      end
      reg.scopes[scope] = nil
    end,
  }
  reg.scopes[scope] = true
  return scope
end

---Number of live registrations, to check for leaks after a reload.
---@return { menus: integer, keys: integer, notifiers: integer, timers: integer, scopes: integer }
function reg.counts()
  local scopes = 0
  for _ in pairs(reg.scopes) do
    scopes = scopes + 1
  end
  return {
    menus = #reg.menus,
    keys = #reg.keys,
    notifiers = #reg.notifiers,
    timers = #reg.timers,
    scopes = scopes,
  }
end

-- Deferral -------------------------------------------------------------------

---@type fun()[]
local deferred = {}

local function run_deferred()
  renoise.tool().app_idle_observable:remove_notifier(run_deferred)
  local queue = deferred
  deferred = {}
  for _, fn in ipairs(queue) do
    pcall(App.guard(fn)) -- guard logs the error, pcall keeps the queue going
  end
end

---Queue `fn` (once) for the next idle tick, after Renoise has finished the
---current operation. Song list notifiers (`tracks_observable`,
---`instruments_observable`, `sequencer.pattern_sequence_observable`,
---`phrase_mappings_observable`) fire *during* the edit: inside them the list is
---updated but patterns, sequence and selection are not, and the song must not
---be modified. Observe the dependent object when it has an observable;
---otherwise defer the work with this.
---https://forum.renoise.com/t/79511  https://forum.renoise.com/t/33796/11
---@param fn fun()
function App.defer(fn)
  if table.find(deferred, fn) then
    return
  end
  table.insert(deferred, fn)
  local idle = renoise.tool().app_idle_observable
  if not idle:has_notifier(run_deferred) then
    idle:add_notifier(run_deferred)
  end
end

-- Dialogs --------------------------------------------------------------------

---@param name string
---@param dialog renoise.Dialog
---@param vb renoise.ViewBuilder
---@param root renoise.Views.View
function App.register_dialog(name, dialog, vb, root)
  App.dialogs[name] = { dialog = dialog, vb = vb, root = root }
end

function App.close_dialogs()
  for name, entry in pairs(App.dialogs) do
    if entry.dialog.visible then
      entry.dialog:close()
    end
    if entry.scope then
      entry.scope.release()
    end
    App.dialogs[name] = nil
  end
end

---Show the main dialog, creating it if needed.
function App.show_dialog()
  local existing = App.dialogs.main
  if existing and existing.dialog.visible then
    existing.dialog:show()
    return
  end
  if existing and existing.scope then
    existing.scope.release() -- the user closed the window: drop its timer and notifiers
  end
  local ui = require "src.ui"
  local vb, root, handlers = ui.build(App)
  handlers = handlers or {}
  local dialog = renoise.app():show_custom_dialog(
    App.name,
    root,
    handlers.key_handler,
    handlers.key_options,
    handlers.focus_handler
  )
  App.register_dialog("main", dialog, vb, root)
  App.dialogs.main.scope = handlers.scope
  if handlers.attach then
    handlers.attach(dialog)
  end
  App.ui = handlers
end

-- Lifecycle ------------------------------------------------------------------

function App.start()
  local session = require "src.session"
  session.init(App)
  App.session = session
  reg.menu {
    name = App.menu_entry,
    invoke = App.guard(App.show_dialog),
  }
  reg.key {
    name = App.keybinding,
    invoke = App.guard(App.show_dialog),
  }
  -- Close dialogs when the song changes so no view keeps stale song references.
  local tool = renoise.tool()
  reg.notifier(tool.app_new_document_observable, App.close_dialogs)
  -- The takes live in the song (`tool_data`): write them before a save, and
  -- forget the old song's state when the song goes away.
  reg.notifier(tool.app_will_save_document_observable, App.guard(session.save))
  reg.notifier(tool.app_release_document_observable, App.guard(session.release))
  -- A full reload does not call `App.stop()`: keep the takes in the song here.
  reg.notifier(tool.tool_will_unload_observable, function()
    pcall(session.shutdown)
  end)
  App.log "started"
end

function App.stop()
  if App.session then
    pcall(App.session.shutdown) -- keep the takes in the song across a reload
  end
  App.close_dialogs()
  for scope in pairs(reg.scopes) do
    scope.release()
  end
  local tool = renoise.tool()
  for _, name in ipairs(reg.menus) do
    if tool:has_menu_entry(name) then
      tool:remove_menu_entry(name)
    end
  end
  for _, name in ipairs(reg.keys) do
    if tool:has_keybinding(name) then
      tool:remove_keybinding(name)
    end
  end
  for _, n in ipairs(reg.notifiers) do
    -- The observable may belong to a song that no longer exists.
    pcall(function()
      if n.observable:has_notifier(n.fn) then
        n.observable:remove_notifier(n.fn)
      end
    end)
  end
  for _, fn in ipairs(reg.timers) do
    if tool:has_timer(fn) then
      tool:remove_timer(fn)
    end
  end
  deferred = {}
  if tool.app_idle_observable:has_notifier(run_deferred) then
    tool.app_idle_observable:remove_notifier(run_deferred)
  end
  reg.menus, reg.keys, reg.notifiers, reg.timers = {}, {}, {}, {}
  App.log "stopped"
end

return App
