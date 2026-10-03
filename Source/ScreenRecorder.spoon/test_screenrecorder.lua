-- test_screenrecorder.lua: unit tests for ScreenRecorder.spoon (run from repo root)
package.path = "Source/ScreenRecorder.spoon/?.lua;" .. package.path

local passed = 0
local failed = 0

local function assert_equal(expected, actual, msg)
  if expected == actual then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL: %s (expected: %s, got: %s)\n", msg, tostring(expected), tostring(actual)))
  end
end

local function assert_true(condition, msg)
  assert_equal(true, condition and true or false, msg)
end

-- Mock state
local existingFiles = {}      -- path -> size
local settingsStore = {}
local alerts = {}
local tasks = {}
local pasteboardWrites = {}
local executeResult = { "", false }
local lastTap = nil

local function newMockCanvas(frame)
  local canvas = { frame = frame, shown = false, deleted = false }
  function canvas:level() return self end
  function canvas:show() self.shown = true; return self end
  function canvas:delete() self.deleted = true end
  return canvas
end

_G.hs = {
  fs = {
    attributes = function(path, attribute)
      local size = existingFiles[path]
      if size == nil then return nil end
      if attribute == "size" then return size end
      return { size = size }
    end,
  },
  execute = function() return executeResult[1], executeResult[2] end,
  settings = {
    get = function(key) return settingsStore[key] end,
    set = function(key, value) settingsStore[key] = value end,
  },
  menubar = {
    new = function()
      local item = {}
      function item:setTitle(title) self.title = title end
      function item:setMenu(menuFn) self.menuFn = menuFn end
      function item:delete() self.deleted = true end
      return item
    end,
  },
  styledtext = { new = function(text, attributes) return { text = text, attributes = attributes } end },
  task = {
    new = function(path, callback, args)
      local task = { path = path, callback = callback, args = args }
      function task:start() self.started = true; return self end
      function task:interrupt() self.interrupted = true end
      table.insert(tasks, task)
      return task
    end,
  },
  timer = { doEvery = function() return { stop = function(self) self.stopped = true end } end },
  canvas = { new = newMockCanvas, windowLevels = { overlay = 102 } },
  alert = { show = function(message) table.insert(alerts, message) end },
  pasteboard = { writeObjects = function(object) table.insert(pasteboardWrites, object) end },
  spoons = {
    bindHotkeysToSpec = function(def, mapping) _G.hs.spoons.lastBound = { def = def, mapping = mapping } end,
  },
  mouse = {
    getCurrentScreen = function()
      return { fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
    end,
  },
  keycodes = { map = { escape = 53 } },
  eventtap = {
    event = { types = { leftMouseDown = 1, leftMouseUp = 2, leftMouseDragged = 6, keyDown = 10 } },
    new = function(types, handler)
      lastTap = { types = types, handler = handler }
      function lastTap:start() self.running = true; return self end
      function lastTap:stop() self.running = false; return self end
      return lastTap
    end,
  },
}

local function fakeEvent(eventType, x, y, keyCode)
  return {
    getType = function() return eventType end,
    location = function() return { x = x, y = y } end,
    getKeyCode = function() return keyCode end,
  }
end

local recorder = require("init")

-- [Test 1] Unique base names
print("\n[Test 1] Unique base names")
existingFiles = {}
assert_equal("/out/Capture-2026-10-03-143512", recorder._uniqueBaseName("/out", "2026-10-03-143512"), "no collision uses plain timestamp")
existingFiles = { ["/out/Capture-2026-10-03-143512.mov"] = 1 }
assert_equal("/out/Capture-2026-10-03-143512-2", recorder._uniqueBaseName("/out", "2026-10-03-143512"), "existing .mov forces -2")
existingFiles = {
  ["/out/Capture-2026-10-03-143512.gif"] = 1,
  ["/out/Capture-2026-10-03-143512-2.mov"] = 1,
}
assert_equal("/out/Capture-2026-10-03-143512-3", recorder._uniqueBaseName("/out", "2026-10-03-143512"), "existing .gif and -2.mov force -3")

-- [Test 2] screencapture arguments
print("\n[Test 2] screencapture arguments")
assert_equal("-v -k -R 10,20,300,200 -V 30 /out/a.mov",
  table.concat(recorder._screencaptureArgs({ x = 10.6, y = 20, w = 300, h = 200 }, 30, "/out/a.mov"), " "),
  "rect floored and -V included")
assert_equal("-v -k -R 10,20,300,200 /out/a.mov",
  table.concat(recorder._screencaptureArgs({ x = 10, y = 20, w = 300, h = 200 }, 0, "/out/a.mov"), " "),
  "no -V when max length is No limit")

-- [Test 3] ffmpeg arguments
print("\n[Test 3] ffmpeg arguments")
assert_equal("-y -i /out/a.mov -vf fps=10,scale='min(800,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse /out/a.gif",
  table.concat(recorder._ffmpegArgs("/out/a.mov", "/out/a.gif"), " "),
  "ffmpeg palette conversion args")

-- [Test 4] ffmpeg discovery
print("\n[Test 4] ffmpeg discovery")
existingFiles = { ["/opt/homebrew/bin/ffmpeg"] = 1, ["/usr/local/bin/ffmpeg"] = 1 }
assert_equal("/opt/homebrew/bin/ffmpeg", recorder._findFfmpeg(), "homebrew arm path preferred")
existingFiles = { ["/usr/local/bin/ffmpeg"] = 1 }
assert_equal("/usr/local/bin/ffmpeg", recorder._findFfmpeg(), "homebrew intel path second")
existingFiles = {}
executeResult = { "/custom/bin/ffmpeg\n", true }
assert_equal("/custom/bin/ffmpeg", recorder._findFfmpeg(), "falls back to PATH lookup, trimmed")
executeResult = { "", false }
assert_equal(nil, recorder._findFfmpeg(), "nil when not installed")

-- [Test 5] Max length setting
print("\n[Test 5] Max length setting")
settingsStore = {}
assert_equal(30, recorder:maxSeconds(), "default max length is 30 s")
recorder:setMaxSeconds(60)
assert_equal(60, recorder:maxSeconds(), "max length updated")
assert_equal(60, settingsStore["ScreenRecorder.maxSeconds"], "max length persisted to hs.settings")
recorder:setMaxSeconds(0)
assert_equal(0, recorder:maxSeconds(), "No limit (0) is kept, not replaced by default")
recorder:setMaxSeconds(30)

-- [Test 6] Menubar
print("\n[Test 6] Menubar")
recorder:start()
assert_true(recorder.menuBarItem ~= nil, "start() creates menubar item")
assert_equal("◉", recorder.menuBarItem.title, "idle title")
local items = recorder.menuBarItem.menuFn()
assert_equal("Start Recording", items[1].title, "first item starts recording")
assert_equal("Max Length", items[2].title, "second item is Max Length submenu")
assert_equal(4, #items[2].menu, "four max length choices")
assert_equal("30 s", items[2].menu[2].title, "30 s label")
assert_equal("No limit", items[2].menu[4].title, "No limit label")
assert_true(items[2].menu[2].checked, "current max length is checked")
assert_true(not items[2].menu[1].checked, "other max lengths unchecked")
items[2].menu[3].fn()
assert_equal(60, recorder:maxSeconds(), "choosing 60 s from menu updates setting")
recorder:setMaxSeconds(30)
assert_equal("Open Output Folder", items[3].title, "third item opens output folder")

-- [Test 7] Hotkeys
print("\n[Test 7] Hotkeys")
recorder:bindHotkeys({ toggle = { { "cmd", "shift" }, "r" } })
assert_true(_G.hs.spoons.lastBound ~= nil and _G.hs.spoons.lastBound.def.toggle ~= nil, "toggle hotkey bound via bindHotkeysToSpec")

-- [Test 8] stop() removes menubar
print("\n[Test 8] stop()")
local menuBarItem = recorder.menuBarItem
recorder:stop()
assert_true(menuBarItem.deleted, "menubar item deleted")
assert_equal(nil, recorder.menuBarItem, "menuBarItem cleared")
recorder:start()

-- Results
print(string.format("\n=========================================\nTest Results: %d Passed, %d Failed\n=========================================", passed, failed))
if failed > 0 then os.exit(1) end
