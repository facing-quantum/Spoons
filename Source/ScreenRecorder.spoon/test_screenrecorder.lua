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
local keyStrokes = {}
local logLines = {}
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
  logger = {
    new = function()
      local function record(level) return function(message) table.insert(logLines, level .. ": " .. message) end end
      return { i = record("i"), w = record("w"), e = record("e") }
    end,
  },
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
    keyStroke = function(mods, key) table.insert(keyStrokes, table.concat(mods, "+") .. "+" .. key) end,
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

-- file moves/deletes are stubbed so tests never touch the real filesystem
local renames, removals = {}, {}
local renameSucceeds = true
os.rename = function(from, to)
  table.insert(renames, { from = from, to = to })
  if renameSucceeds then return true end
  return nil, "Cross-device link"
end
os.remove = function(path) table.insert(removals, path); return true end

local tempDir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
local function outputPath(movPath, ext)
  return "/out/" .. movPath:match("([^/]+)%.mov$") .. "." .. ext
end

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
existingFiles = { [tempDir .. "/Capture-2026-10-03-143512.mov"] = 1 }
assert_equal("/out/Capture-2026-10-03-143512-2", recorder._uniqueBaseName("/out", "2026-10-03-143512"), "temp mov still being converted forces -2")
for _, ext in ipairs({ "webp", "avif", "mp4" }) do
  existingFiles = { ["/out/Capture-2026-10-03-143512." .. ext] = 1 }
  assert_equal("/out/Capture-2026-10-03-143512-2", recorder._uniqueBaseName("/out", "2026-10-03-143512"), "existing ." .. ext .. " forces -2")
end

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
local animatedScale = "fps=10,scale='trunc(min(800,iw)/2)*2':-2:flags=lanczos"
assert_equal("-y -i /out/a.mov -an -vf " .. animatedScale
    .. ",split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle /out/a.gif",
  table.concat(recorder._ffmpegArgs("gif", "/out/a.mov", "/out/a.gif", 10, 800), " "),
  "gif: diff palette, rectangle updates, bayer dither")
assert_equal("-y -i /out/a.mov -an -vf " .. animatedScale .. " -c:v libwebp_anim -quality 80 -loop 0 /out/a.webp",
  table.concat(recorder._ffmpegArgs("webp", "/out/a.mov", "/out/a.webp", 10, 800), " "),
  "webp: libwebp_anim (inter-frame) quality 80, looping")
assert_equal("-y -i /out/a.mov -an -vf " .. animatedScale .. " -c:v libaom-av1 -crf 30 -b:v 0 -cpu-used 6 -pix_fmt yuv420p /out/a.avif",
  table.concat(recorder._ffmpegArgs("avif", "/out/a.mov", "/out/a.avif", 10, 800), " "),
  "avif: libaom crf 30")
assert_equal("-y -i /out/a.mov -an -vf scale=trunc(iw/2)*2:trunc(ih/2)*2 -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p -movflags +faststart /out/a.mp4",
  table.concat(recorder._ffmpegArgs("mp4", "/out/a.mov", "/out/a.mp4", 10, 800), " "),
  "mp4: native size and frame rate, even dimensions")
assert_true(table.concat(recorder._ffmpegArgs("gif", "/out/a.mov", "/out/a.gif", 15, 640), " "):find("fps=15,scale='trunc(min(640,iw)/2)*2'", 1, true) ~= nil,
  "animation fps and max width come from the arguments")

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

-- [Test 5b] Output format setting
print("\n[Test 5b] Output format setting")
settingsStore = {}
assert_equal("gif", recorder.outputFormat, "outputFormat defaults to gif")
assert_equal(10, recorder.animationFps, "animationFps defaults to 10")
assert_equal(800, recorder.animationMaxWidth, "animationMaxWidth defaults to 800")
assert_equal("gif", recorder:format(), "format() falls back to outputFormat when nothing is saved")
recorder.outputFormat = "webp"
assert_equal("webp", recorder:format(), "format() follows outputFormat from init.lua")
recorder:setFormat("mp4")
assert_equal("mp4", settingsStore["ScreenRecorder.outputFormat"], "chosen format persisted to hs.settings")
assert_equal("mp4", recorder:format(), "saved menu choice takes precedence over outputFormat")
recorder.outputFormat = "gif"
settingsStore = {}

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
assert_equal("Format", items[3].title, "third item is Format submenu")
assert_equal("GIF WebP AVIF MP4", items[3].menu[1].title .. " " .. items[3].menu[2].title .. " " .. items[3].menu[3].title .. " " .. items[3].menu[4].title, "format labels in order")
assert_true(items[3].menu[1].checked, "current format (gif) is checked")
assert_true(not items[3].menu[4].checked, "other formats unchecked")
items[3].menu[4].fn()
assert_equal("mp4", recorder:format(), "choosing MP4 from menu selects it")
assert_true(recorder.menuBarItem.menuFn()[3].menu[4].checked, "MP4 checked after choosing it")
settingsStore = {}
assert_equal("Open Output Folder", items[4].title, "fourth item opens output folder")

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

-- [Test 9] Area selection
print("\n[Test 9] Area selection")
local types = _G.hs.eventtap.event.types
local selectedRect = nil
local realStartRecording = recorder._startRecording
recorder._startRecording = function(_, rect) selectedRect = rect end

recorder:toggleRecording()
assert_true(recorder._selector ~= nil, "toggle starts selection")
assert_true(lastTap.running, "eventtap running during selection")
local overlay = recorder._selector.canvas
assert_true(overlay.shown, "overlay shown")
lastTap.handler(fakeEvent(types.leftMouseDown, 300, 400))
lastTap.handler(fakeEvent(types.leftMouseDragged, 200, 250))
assert_equal(100, overlay[2].frame.w, "selection rectangle drawn while dragging")
lastTap.handler(fakeEvent(types.leftMouseUp, 100, 200))
assert_true(selectedRect ~= nil, "selection callback fired")
assert_equal(100, selectedRect.x, "rect normalized x")
assert_equal(200, selectedRect.y, "rect normalized y")
assert_equal(200, selectedRect.w, "rect width")
assert_equal(200, selectedRect.h, "rect height")
assert_equal(nil, recorder._selector, "selector cleared after mouse up")
assert_true(overlay.deleted, "overlay deleted")
assert_true(not lastTap.running, "eventtap stopped")

selectedRect = nil
recorder:toggleRecording()
lastTap.handler(fakeEvent(types.leftMouseDown, 10, 10))
lastTap.handler(fakeEvent(types.leftMouseUp, 15, 15))
assert_equal(nil, selectedRect, "tiny drag cancels silently")
assert_equal(nil, recorder._selector, "selector cleared after tiny drag")

recorder:toggleRecording()
assert_equal(false, lastTap.handler(fakeEvent(types.keyDown, 0, 0, 0)), "other keys pass through")
assert_equal(true, lastTap.handler(fakeEvent(types.keyDown, 0, 0, 53)), "escape is consumed")
assert_equal(nil, recorder._selector, "escape cancels selection")

recorder:toggleRecording()
recorder:toggleRecording()
assert_equal(nil, recorder._selector, "toggle during selection cancels it")
assert_equal(nil, selectedRect, "no recording after cancel")

selectedRect = nil
recorder:toggleRecording()
lastTap.handler(fakeEvent(types.leftMouseDown, 1400, 850))
lastTap.handler(fakeEvent(types.leftMouseUp, 1600, 1000))
assert_true(selectedRect ~= nil, "off-screen drag still selects")
assert_equal(1400, selectedRect.x, "clamped rect x")
assert_equal(850, selectedRect.y, "clamped rect y")
assert_equal(40, selectedRect.w, "rect width clamped to screen edge")
assert_equal(50, selectedRect.h, "rect height clamped to screen edge")

recorder._startRecording = realStartRecording

-- [Test 10] Recording and delivery
print("\n[Test 10] Recording and delivery")
local function lastTask() return tasks[#tasks] end
recorder.outputDir = "/out"
existingFiles = {}
executeResult = { "", false }

recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
local captureTask = lastTask()
local movPath = captureTask.args[#captureTask.args]
assert_equal("/usr/sbin/screencapture", captureTask.path, "runs screencapture")
assert_true(captureTask.started, "screencapture started")
assert_true(movPath:match("/Capture%-%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d%d%d%.mov$") ~= nil, "mov path uses timestamped base name")
assert_equal(tempDir .. "/", movPath:sub(1, #tempDir + 1), "mov is recorded into the temp folder, not outputDir")
assert_true(table.concat(captureTask.args, " "):find("-R 10,20,300,200 -V 30", 1, true) ~= nil, "region and max length passed")
local border = recorder._recording.border
assert_true(border.shown, "border shown")
assert_equal(7, border.frame.x, "border sits outside the rect")
assert_equal(306, border.frame.w, "border width covers rect plus both edges")
assert_true(recorder.menuBarItem.title.text:match("^● %d+s$") ~= nil, "menubar shows recording")

recorder:toggleRecording()
assert_equal("cmd+ctrl+escape", keyStrokes[#keyStrokes], "toggle while recording sends the system stop-recording shortcut")
assert_true(not captureTask.interrupted, "screencapture is not interrupted (SIGINT discards the recording)")

-- finish without ffmpeg
existingFiles[movPath] = 1000
local alertCount = #alerts
captureTask.callback(0, "", "")
assert_equal(nil, recorder._recording, "recording state cleared")
assert_true(border.deleted, "border removed")
assert_equal("◉", recorder.menuBarItem.title, "menubar back to idle")
assert_equal("file://" .. outputPath(movPath, "mov"), pasteboardWrites[#pasteboardWrites].url, "mov moved to outputDir and copied when ffmpeg missing")
assert_equal(movPath, renames[#renames].from, "temp mov is the move source")
assert_equal(outputPath(movPath, "mov"), renames[#renames].to, "mov moved next to where the converted file would go")
assert_equal("/usr/bin/open", lastTask().path, "reveals in Finder")
assert_equal("-R " .. outputPath(movPath, "mov"), table.concat(lastTask().args, " "), "open -R on the kept mov")
assert_equal(alertCount + 1, #alerts, "one alert about missing ffmpeg")

recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")
assert_equal(alertCount + 1, #alerts, "missing-ffmpeg alert shown only once")

-- finish with ffmpeg, success
existingFiles = { ["/opt/homebrew/bin/ffmpeg"] = 1 }
recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
local gifPath = outputPath(movPath, "gif")
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")
local ffmpegTask = lastTask()
assert_equal("/opt/homebrew/bin/ffmpeg", ffmpegTask.path, "runs ffmpeg")
assert_equal(gifPath, ffmpegTask.args[#ffmpegTask.args], "gif shares the mov base name")
assert_equal(true, recorder._converting[ffmpegTask], "ffmpeg task retained in _converting")
ffmpegTask.callback(0, "", "")
assert_equal("file://" .. gifPath, pasteboardWrites[#pasteboardWrites].url, "gif copied to clipboard")
assert_equal(movPath, removals[#removals], "temp mov deleted after successful conversion")
assert_equal(nil, recorder._converting[ffmpegTask], "_converting cleared after callback")

-- finish with ffmpeg, failure
recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")
lastTask().callback(1, "", "boom")
assert_true(alerts[#alerts]:find("boom", 1, true) ~= nil, "ffmpeg stderr shown")
assert_equal("file://" .. outputPath(movPath, "mov"), pasteboardWrites[#pasteboardWrites].url, "mov kept in outputDir and copied when ffmpeg fails")

-- screencapture failure (no file produced)
local writesBefore = #pasteboardWrites
recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
local failedTimer = recorder._recording.timer
captureTask.callback(2, "", "screencapture: illegal option")
assert_true(logLines[#logLines]:find("exit 2", 1, true) ~= nil, "exit code logged to console")
assert_true(logLines[#logLines]:find("screencapture: illegal option", 1, true) ~= nil, "screencapture stderr logged to console")
assert_true(logLines[#logLines]:find("command: /usr/sbin/screencapture -v -k -R 10,20,300,200", 1, true) ~= nil, "failing command included in the error line")
assert_true(alerts[#alerts]:find("console", 1, true) ~= nil, "alert points to the console")
assert_true(alerts[#alerts]:find("Screen Recording", 1, true) ~= nil, "permission hint shown")
assert_equal(writesBefore, #pasteboardWrites, "nothing copied on failure")
assert_equal(nil, recorder._recording, "state cleared on failure")
assert_true(failedTimer.stopped, "elapsed timer stopped")

-- fractional rect: border and capture region use the same floored rect
recorder:_startRecording({ x = 10.7, y = 20.4, w = 300.9, h = 200.2 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
border = recorder._recording.border
assert_equal(7, border.frame.x, "border x from floored rect")
assert_equal(17, border.frame.y, "border y from floored rect")
assert_equal(306, border.frame.w, "border w from floored rect")
assert_equal(206, border.frame.h, "border h from floored rect")
assert_true(table.concat(captureTask.args, " "):find("-R 10,20,300,200", 1, true) ~= nil, "capture region floored")
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")

-- concurrent conversions are all retained until their own callback
existingFiles = { ["/opt/homebrew/bin/ffmpeg"] = 1 }
local converting = {}
local gifs = {}
for i = 1, 2 do
  recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
  captureTask = lastTask()
  movPath = captureTask.args[#captureTask.args]
  gifs[i] = outputPath(movPath, "gif")
  existingFiles[movPath] = 1000
  captureTask.callback(0, "", "")
  converting[i] = lastTask()
end
assert_true(converting[1] ~= converting[2], "two distinct ffmpeg tasks")
assert_equal(true, recorder._converting[converting[1]], "first conversion retained")
assert_equal(true, recorder._converting[converting[2]], "second conversion retained")
converting[2].callback(0, "", "")
assert_equal(nil, recorder._converting[converting[2]], "second conversion released")
assert_equal(true, recorder._converting[converting[1]], "first still retained after second finishes")
assert_equal("file://" .. gifs[2], pasteboardWrites[#pasteboardWrites].url, "second gif copied")
converting[1].callback(0, "", "")
assert_equal(nil, recorder._converting[converting[1]], "first conversion released")
assert_equal("file://" .. gifs[1], pasteboardWrites[#pasteboardWrites].url, "first gif copied")

-- [Test 11] Converting to the selected format
print("\n[Test 11] Selected format conversion")
existingFiles = { ["/opt/homebrew/bin/ffmpeg"] = 1 }
recorder:setFormat("mp4")
recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
local mp4Path = outputPath(movPath, "mp4")
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")
ffmpegTask = lastTask()
assert_equal(mp4Path, ffmpegTask.args[#ffmpegTask.args], "converts to the selected format, sharing the mov base name")
assert_true(table.concat(ffmpegTask.args, " "):find("libx264", 1, true) ~= nil, "mp4 encoder used")
ffmpegTask.callback(0, "", "")
assert_equal("file://" .. mp4Path, pasteboardWrites[#pasteboardWrites].url, "selected format copied to clipboard")

recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")
lastTask().callback(1, "", "Unknown encoder")
assert_true(alerts[#alerts]:find("MP4 export failed", 1, true) ~= nil, "alert names the failed format")
assert_equal("file://" .. outputPath(movPath, "mov"), pasteboardWrites[#pasteboardWrites].url, "mov kept in outputDir and copied when conversion fails")

-- move to outputDir fails (e.g. outputDir on another volume): deliver from temp and warn
renameSucceeds = false
recorder:_startRecording({ x = 10, y = 20, w = 300, h = 200 })
captureTask = lastTask()
movPath = captureTask.args[#captureTask.args]
existingFiles[movPath] = 1000
captureTask.callback(0, "", "")
lastTask().callback(1, "", "Unknown encoder")
assert_equal("file://" .. movPath, pasteboardWrites[#pasteboardWrites].url, "temp mov delivered when it cannot be moved")
assert_true(logLines[#logLines]:find("could not move", 1, true) ~= nil, "failed move logged")
renameSucceeds = true
settingsStore = {}

-- Results
print(string.format("\n=========================================\nTest Results: %d Passed, %d Failed\n=========================================", passed, failed))
if failed > 0 then os.exit(1) end
