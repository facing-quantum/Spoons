-- test_caffeine.lua: Comprehensive unit tests for modernized Caffeine.spoon
package.path = "Source/Caffeine.spoon/?.lua;" .. package.path

local passed = 0
local failed = 0

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    io.stderr:write(string.format("FAIL: %s (expected: %s, got: %s)\n", msg or "assertion failed", tostring(expected), tostring(actual)))
    failed = failed + 1
    error("test failed: " .. (msg or ""))
  else
    passed = passed + 1
  end
end

local function assert_true(condition, msg)
  if not condition then
    io.stderr:write(string.format("FAIL: %s (expected truthy, got: %s)\n", msg or "assertion failed", tostring(condition)))
    failed = failed + 1
    error("test failed: " .. (msg or ""))
  else
    passed = passed + 1
  end
end

-- Mock State
local mockCaffeinateState = { displayIdle = false, systemIdle = false }
local mockPowerSource = "AC Power"
local mockTimers = {}

-- Mock Image Object
local function newMockImage()
  local img = { _isImage = true, _template = false }
  function img:template(val)
    if val ~= nil then self._template = val end
    return self._template
  end
  return img
end

-- Mock Canvas
local createdCanvases = {}
local mockCanvas = {
  new = function(frame)
    local c = {
      _frame = frame,
      _elements = {},
      _deleted = false
    }
    function c:appendElements(elem)
      table.insert(self._elements, elem)
      return self
    end
    function c:imageFromCanvas()
      return newMockImage()
    end
    function c:delete()
      self._deleted = true
    end
    table.insert(createdCanvases, c)
    return c
  end
}

-- Mock Menubar
local mockMenubar = {
  _icon = nil,
  _tooltip = nil,
  _clickCallback = nil,
  _deleted = false,
  _menu = nil,
  new = function(inMenubar)
    local mb = {
      _icon = nil,
      _tooltip = nil,
      _clickCallback = nil,
      _deleted = false,
      _menu = nil,
      _inMenubar = (inMenubar ~= false)
    }
    function mb:setIcon(icon) self._icon = icon return self end
    function mb:setTooltip(tip) self._tooltip = tip return self end
    function mb:setClickCallback(fn) self._clickCallback = fn return self end
    function mb:setMenu(menu) self._menu = menu return self end
    function mb:popupMenu(pos) self._poppedPos = pos return self end
    function mb:frame() return { x = 600, y = 0, w = 24, h = 24 } end
    function mb:delete() self._deleted = true return self end
    return mb
  end
}

-- Mock Watchers
local mockWatcher = {
  systemDidWake = 1,
  screensDidWake = 2,
  _fn = nil,
  _running = false,
  new = function(fn)
    local w = { _fn = fn, _running = false }
    function w:start() self._running = true return self end
    function w:stop() self._running = false return self end
    return w
  end
}

local mockBatteryWatcher = {
  _fn = nil,
  _running = false,
  new = function(fn)
    local w = { _fn = fn, _running = false }
    function w:start() self._running = true return self end
    function w:stop() self._running = false return self end
    return w
  end
}

-- Mock Eventtap
local mockKeyboardModifiers = {}
local mockEventTap = {
  event = {
    types = { rightMouseDown = 100 }
  },
  checkKeyboardModifiers = function() return mockKeyboardModifiers end,
  new = function(types, fn)
    local et = { types = types, fn = fn, _running = false }
    function et:start() self._running = true return self end
    function et:stop() self._running = false return self end
    return et
  end
}

-- Mock Chooser
local mockChooser
mockChooser = {
  lastInstance = nil,
  new = function(fn)
    local c = { _fn = fn, _choices = {}, _shown = false }
    function c:choices(ch) self._choices = ch return self end
    function c:placeholderText(txt) self._placeholder = txt return self end
    function c:show() self._shown = true return self end
    mockChooser.lastInstance = c
    return c
  end
}

-- Mock Timer
local mockTimer = {
  doAfter = function(seconds, fn)
    local t = { seconds = seconds, fn = fn, _stopped = false, _type = "doAfter" }
    function t:stop() self._stopped = true end
    function t:trigger() if not self._stopped then self.fn() end end
    table.insert(mockTimers, t)
    return t
  end,
  doEvery = function(interval, fn)
    local t = { interval = interval, fn = fn, _stopped = false, _type = "doEvery" }
    function t:stop() self._stopped = true end
    function t:trigger() if not self._stopped then self.fn() end end
    table.insert(mockTimers, t)
    return t
  end
}

-- Mock Hotkeys
local mockHotkeys = {}
local mockHotkey = {
  new = function(mods, key, fn)
    local hk = { mods = mods, key = key, fn = fn, _enabled = false, _deleted = false }
    function hk:enable() self._enabled = true return self end
    function hk:disable() self._enabled = false return self end
    function hk:delete() self._deleted = true return self end
    table.insert(mockHotkeys, hk)
    return hk
  end,
  bind = function(mods, key, fn)
    local hk = mockHotkey.new(mods, key, fn)
    hk:enable()
    return hk
  end
}

local mockSettingsStore = {}
local mockSettings = {
  get = function(key) return mockSettingsStore[key] end,
  set = function(key, val) mockSettingsStore[key] = val end
}

_G.hs = {
  host = {
    operatingSystemVersion = function() return { major = 26, minor = 0, patch = 0 } end
  },
  settings = mockSettings,
  canvas = mockCanvas,
  caffeinate = {
    get = function(kind) return mockCaffeinateState[kind] end,
    set = function(kind, val) mockCaffeinateState[kind] = val end,
    toggle = function(kind)
      mockCaffeinateState[kind] = not mockCaffeinateState[kind]
      return mockCaffeinateState[kind]
    end,
    watcher = mockWatcher
  },
  battery = {
    powerSource = function() return mockPowerSource end,
    watcher = mockBatteryWatcher
  },
  eventtap = mockEventTap,
  mouse = {
    absolutePosition = function() return { x = 605, y = 10 } end
  },
  menubar = mockMenubar,
  chooser = mockChooser,
  hotkey = mockHotkey,
  timer = mockTimer,
  image = {
    imageFromPath = function(path)
      local img = newMockImage()
      img._path = path
      return img
    end,
    imageFromASCII = function() return newMockImage() end
  },
  spoons = {
    scriptPath = function() return "Source/Caffeine.spoon" end,
    bindHotkeysToSpec = function(def, mapping)
      _G.hs.spoons.lastBound = { def = def, mapping = mapping }
      if mapping and mapping.toggle then
        local hk = mockHotkey.new(mapping.toggle[1], mapping.toggle[2], def.toggle)
        hk:enable()
      end
      if mapping and mapping.menu then
        local hk = mockHotkey.new(mapping.menu[1], mapping.menu[2], def.menu)
        hk:enable()
      end
    end
  }
}

print("--- Running Caffeine.spoon Test Suite ---")

local caffeine = require("init")

-- [Test 1] Metadata & Version
print("\n[Test 1] Metadata & Version")
assert_equal("Caffeine", caffeine.name, "Spoon name is Caffeine")
assert_equal("1.4", caffeine.version, "Spoon version is 1.4")

-- [Test 2] State Inspection (getState and isCaffeinated)
print("\n[Test 2] State Inspection")
mockCaffeinateState.displayIdle = false
assert_equal(false, caffeine:getState(), "getState returns false initially")
assert_equal(false, caffeine:isCaffeinated(), "isCaffeinated returns false initially")

mockCaffeinateState.displayIdle = true
assert_equal(true, caffeine:getState(), "getState returns true when active")
assert_equal(true, caffeine:isCaffeinated(), "isCaffeinated returns true when active")

-- [Test 3] Authentic Canvas Vector Icon Generation with Template Caching
print("\n[Test 3] Authentic Canvas Vector Icon Generation")
caffeine:start()
assert_true(caffeine._icons ~= nil, "icon cache initialized")
assert_true(caffeine._icons["on"] ~= nil, "on icon generated via hs.canvas")
assert_true(caffeine._icons["off"] ~= nil, "off icon generated via hs.canvas")
assert_true(caffeine._icons["on"]._template == true, "on icon template flag is true")
assert_true(caffeine._icons["off"]._template == true, "off icon template flag is true")
assert_true(#createdCanvases >= 2, "canvases created for icon generation")
assert_true(createdCanvases[1]._deleted and createdCanvases[2]._deleted, "canvases cleaned up after rasterization")
caffeine:stop()

-- [Test 4] Full Lifecycle (start and stop)
print("\n[Test 4] Lifecycle")
caffeine:start()
assert_true(caffeine.menuBarItem ~= nil, "menuBarItem created on start")
assert_true(not caffeine.menuBarItem._deleted, "menuBarItem active")
assert_true(caffeine.sleepWatcher ~= nil and caffeine.sleepWatcher._running, "sleepWatcher running")
assert_true(caffeine.batteryWatcher ~= nil and caffeine.batteryWatcher._running, "batteryWatcher running")
assert_true(caffeine.rightClickTap ~= nil and caffeine.rightClickTap._running, "rightClickTap running")

caffeine:stop()
assert_equal(nil, caffeine.menuBarItem, "menuBarItem cleaned up on stop")
assert_equal(nil, caffeine.sleepWatcher, "sleepWatcher cleaned up on stop")
assert_equal(nil, caffeine.batteryWatcher, "batteryWatcher cleaned up on stop")
assert_equal(nil, caffeine.rightClickTap, "rightClickTap cleaned up on stop")

-- [Test 5] clicked() with dot and colon syntax
print("\n[Test 5] clicked() toggling")
caffeine:start()
caffeine:setState(false)
assert_equal(false, caffeine:getState(), "caffeinate state is false")
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "inactive tooltip set")

caffeine.clicked()
assert_equal(true, caffeine:getState(), "caffeine.clicked() toggled state to true")
assert_true(caffeine.menuBarItem._tooltip:match("Display sleep prevented") ~= nil, "tooltip active")

caffeine:clicked()
assert_equal(false, caffeine:getState(), "caffeine:clicked() toggled state to false")
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "tooltip inactive")

-- [Test 6] Sleep Modes: displayIdle vs systemIdle
print("\n[Test 6] Sleep Prevention Modes")
caffeine:setPreventType("systemIdle")
assert_equal("systemIdle", caffeine.preventType, "preventType set to systemIdle")
caffeine:setState(true)
assert_equal(true, mockCaffeinateState.systemIdle, "systemIdle set to true")
assert_true(caffeine.menuBarItem._tooltip:match("System sleep prevented") ~= nil, "tooltip specifies system sleep")

caffeine:setPreventType("displayIdle")
assert_equal("displayIdle", caffeine.preventType, "preventType restored to displayIdle")
assert_equal(true, mockCaffeinateState.displayIdle, "displayIdle updated")
assert_true(caffeine.menuBarItem._tooltip:match("Display sleep prevented") ~= nil, "tooltip specifies display sleep")

-- [Test 7] Timed Sessions
print("\n[Test 7] Timed Sessions")
caffeine:startTimed(30)
assert_equal(true, caffeine:getState(), "startTimed activated sleep prevention")
assert_true(caffeine.sessionTimer ~= nil, "sessionTimer created")
assert_true(caffeine.sessionEndTime ~= nil, "sessionEndTime calculated")
assert_true(caffeine.menuBarItem._tooltip:match("30m remaining") ~= nil, "tooltip displays remaining time: " .. caffeine.menuBarItem._tooltip)

-- Trigger timer expiration
caffeine.sessionTimer:trigger()
assert_equal(false, caffeine:getState(), "timer expiration deactivated caffeination")
assert_equal(nil, caffeine.sessionTimer, "timer reference cleared")
assert_equal(nil, caffeine.sessionEndTime, "sessionEndTime cleared")
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "tooltip reset to sleep allowed")

-- [Test 8] Auto-Deactivate on Battery Power & Settings Persistence
print("\n[Test 8] Battery Power Saver & Settings Persistence")
caffeine:setDisableOnBattery(true)
assert_equal(true, caffeine.disableOnBattery, "disableOnBattery enabled")
assert_equal(true, mockSettingsStore["Caffeine.disableOnBattery"], "disableOnBattery persisted to hs.settings")

-- Verify init() restores persisted settings
caffeine.disableOnBattery = false
caffeine:init()
assert_equal(true, caffeine.disableOnBattery, "disableOnBattery restored from hs.settings on init()")

-- On AC power: should allow activating
mockPowerSource = "AC Power"
caffeine:setState(true)
assert_equal(true, caffeine:getState(), "caffeination allowed on AC Power")

-- Simulate unplugging (switch to Battery Power)
mockPowerSource = "Battery Power"
caffeine.batteryWatcher._fn()
assert_equal(false, caffeine:getState(), "battery watcher deactivated caffeination when unplugged")

-- Attempting to turn ON while on battery power with disableOnBattery: should stay off
caffeine:setState(true)
assert_equal(false, caffeine:getState(), "setState(true) blocked while on battery power")

caffeine:setDisableOnBattery(false)
mockPowerSource = "AC Power"

-- [Test 9] Context Menu & OS-Adaptive Click Behavior (macOS 26 fallback vs macOS 27 direct toggle)
print("\n[Test 9] Context Menu & OS-Adaptive Click Behavior")
local menu = caffeine:getMenuTable()
assert_true(#menu >= 10, "menu table contains options")
assert_equal("Status: Sleep allowed", menu[1].title, "status header present")

-- 9a: macOS 26 / Darwin 26 path (direct 1-click toggle, modifier-click for menu)
mockSettingsStore["Caffeine.menuOnLeftClick"] = nil
_G.hs.host.operatingSystemVersion = function() return { major = 26, minor = 0, patch = 0 } end
caffeine:stop()
caffeine:init():start()
assert_equal(false, caffeine.menuOnLeftClick, "defaults to menuOnLeftClick = false on macOS 26")
assert_equal(nil, caffeine.menuBarItem._menu, "menu is nil on macOS 26")
assert_true(caffeine.menuBarItem._clickCallback ~= nil, "clickCallback set on macOS 26")

-- Verify modifier click (Option-click / Cmd-click) triggers popupMenu on macOS 26
local origPopupMenu = caffeine.popupMenu
local clickedMenu26 = false
caffeine.popupMenu = function() clickedMenu26 = true end
caffeine.menuBarItem._clickCallback({ alt = true })
assert_true(clickedMenu26, "Option-click triggered popupMenu on macOS 26")

-- Verify modifier detection via hs.eventtap.checkKeyboardModifiers fallback
clickedMenu26 = false
mockKeyboardModifiers = { alt = true }
caffeine.menuBarItem._clickCallback({})
assert_true(clickedMenu26, "checkKeyboardModifiers fallback triggered popupMenu on macOS 26")
mockKeyboardModifiers = {}

-- Verify right-click eventtap triggers popupMenu on macOS 26
local rightClicked26 = false
caffeine.popupMenu = function() rightClicked26 = true end
local mockEventInside = { location = function() return { x = 605, y = 10 } end }
local handled = caffeine.rightClickTap.fn(mockEventInside)
assert_true(handled, "rightClickTap handled click inside frame on macOS 26")
assert_true(rightClicked26, "rightClickTap triggered popupMenu on macOS 26")

-- Verify right-click outside frame is ignored
rightClicked26 = false
local mockEventOutside = { location = function() return { x = 100, y = 100 } end }
local handledOutside = caffeine.rightClickTap.fn(mockEventOutside)
assert_equal(false, handledOutside, "rightClickTap ignored click outside frame")
assert_equal(false, rightClicked26, "popupMenu not called for click outside frame")

-- Restore real popupMenu and verify it invokes native Cocoa popupMenu on macOS 26
caffeine.popupMenu = origPopupMenu
caffeine:popupMenu()
assert_true(caffeine.menuBarItem._poppedPos ~= nil, "popupMenu invoked native Cocoa popupMenu on macOS 26")
assert_equal(nil, caffeine.menuBarItem._menu, "popupMenu cleans up menuBarItem._menu on macOS 26")

-- Verify normal left click directly toggles on macOS 26
caffeine:setState(false)
caffeine.menuBarItem._clickCallback({})
assert_equal(true, caffeine:getState(), "normal left-click toggles state ON on macOS 26")
caffeine.menuBarItem._clickCallback({})
assert_equal(false, caffeine:getState(), "normal left-click toggles state OFF on macOS 26")

-- Verify chooser fallback when native Cocoa popupMenu is unavailable
local origMBPopupMenu = caffeine.menuBarItem.popupMenu
caffeine.menuBarItem.popupMenu = nil
caffeine:popupMenu()
assert_true(mockChooser.lastInstance ~= nil and mockChooser.lastInstance._shown, "hs.chooser fallback invoked when popupMenu unavailable")
assert_true(#mockChooser.lastInstance._choices >= 10, "hs.chooser populated with Caffeine menu choices")
caffeine.menuBarItem.popupMenu = origMBPopupMenu

-- 9b: macOS 27 / Darwin 27 path (direct 1-click toggle, right-click/modifier-click for menu)
mockSettingsStore["Caffeine.menuOnLeftClick"] = nil
_G.hs.host.operatingSystemVersion = function() return { major = 27, minor = 0, patch = 0 } end
caffeine:stop()
caffeine:init():start()
assert_equal(false, caffeine.menuOnLeftClick, "defaults to menuOnLeftClick = false on macOS 27")
assert_equal(nil, caffeine.menuBarItem._menu, "setMenu is nil on macOS 27")
assert_true(caffeine.menuBarItem._clickCallback ~= nil, "clickCallback set on macOS 27")

-- Verify normal left-click directly toggles state
caffeine:setState(false)
caffeine.menuBarItem._clickCallback({})
assert_equal(true, caffeine:getState(), "left click directly toggles state ON")
caffeine.menuBarItem._clickCallback({})
assert_equal(false, caffeine:getState(), "second left click directly toggles state OFF")

-- Verify popupMenu does NOT attach menu to menuBarItem when menuOnLeftClick is false
caffeine:popupMenu()
assert_equal(nil, caffeine.menuBarItem._menu, "popupMenu cleans up menuBarItem._menu")
-- Left click still directly toggles after popupMenu
caffeine.menuBarItem._clickCallback({})
assert_equal(true, caffeine:getState(), "left click still directly toggles ON after popupMenu")
caffeine.menuBarItem._clickCallback({})
assert_equal(false, caffeine:getState(), "left click still directly toggles OFF after popupMenu")

-- 9c: Dynamic user setting override
caffeine:setMenuOnLeftClick(true)
assert_equal(true, caffeine.menuOnLeftClick, "setMenuOnLeftClick(true) updated property")
assert_true(caffeine.menuBarItem._menu ~= nil, "setMenu attached dynamically after setMenuOnLeftClick(true)")

caffeine:setMenuOnLeftClick(false)
assert_equal(false, caffeine.menuOnLeftClick, "setMenuOnLeftClick(false) updated property")
assert_true(caffeine.menuBarItem._clickCallback ~= nil, "clickCallback restored after setMenuOnLeftClick(false)")

-- [Test 10] Hotkey Bindings
print("\n[Test 10] Hotkey Bindings")
caffeine:bindHotkeys({
  toggle = { {"cmd", "alt"}, "c" },
  menu   = { {"cmd", "alt"}, "m" }
})
assert_true(_G.hs.spoons.lastBound ~= nil, "hs.spoons.bindHotkeysToSpec was invoked")
assert_true(_G.hs.spoons.lastBound.def.toggle ~= nil, "toggle hotkey bound")
assert_true(_G.hs.spoons.lastBound.def.menu ~= nil, "menu hotkey bound")

caffeine:stop()

-- [Test 11] Steam Animation Lifecycle & Configurability
print("\n[Test 11] Steam Animation Lifecycle & Configurability")
caffeine:start()
assert_equal(true, caffeine.animateSteam, "animateSteam is true by default")
assert_equal(nil, caffeine.steamTimer, "steamTimer is nil when inactive")

-- Activating Caffeine should start steam animation timer
caffeine:setState(true)
assert_true(caffeine.steamTimer ~= nil, "steamTimer is created when active and animateSteam is true")
assert_true(not caffeine.steamTimer._stopped, "steamTimer is running")
assert_true(caffeine._steamFrames ~= nil and #caffeine._steamFrames == 4, "pre-rendered 4 cyclic steam frames")

-- Timer ticks cycle through frames
local firstIcon = caffeine.menuBarItem._icon
caffeine.steamTimer:trigger()
local secondIcon = caffeine.menuBarItem._icon
assert_true(firstIcon ~= secondIcon, "steam timer tick advances to next animated frame")

-- Screen sleep pauses steam animation; wake resumes it
mockWatcher.screensDidSleep = 3
mockWatcher.systemWillSleep = 4
caffeine.sleepWatcher._fn(mockWatcher.screensDidSleep)
assert_equal(nil, caffeine.steamTimer, "steam animation stopped when screens go to sleep")
caffeine.sleepWatcher._fn(mockWatcher.screensDidWake)
assert_true(caffeine.steamTimer ~= nil and not caffeine.steamTimer._stopped, "steam animation resumed on wake")

-- Context menu toggle check
local menuTable = caffeine:getMenuTable()
local foundAnimateToggle = false
for _, item in ipairs(menuTable) do
  if item.title == "Animate Steam When Active" then
    foundAnimateToggle = true
    assert_equal(true, item.checked, "Animate Steam toggle is checked in menu")
  end
end
assert_true(foundAnimateToggle, "Animate Steam toggle present in context menu")

-- Disabling animation switches to static icon and stops timer
caffeine:setAnimateSteam(false)
assert_equal(false, caffeine.animateSteam, "animateSteam updated to false")
assert_equal(false, mockSettingsStore["Caffeine.animateSteam"], "animateSteam persisted to hs.settings")
assert_equal(nil, caffeine.steamTimer, "steamTimer stopped when animation disabled")
assert_equal(caffeine._icons["on"], caffeine.menuBarItem._icon, "menubar item reset to static ON icon")

-- Re-enabling animation restarts timer while active
caffeine:setAnimateSteam(true)
assert_equal(true, caffeine.animateSteam, "animateSteam updated to true")
assert_true(caffeine.steamTimer ~= nil and not caffeine.steamTimer._stopped, "steamTimer restarted when animation re-enabled")

-- Deactivating Caffeine stops the steam timer
caffeine:setState(false)
assert_equal(nil, caffeine.steamTimer, "steamTimer stopped when Caffeine deactivated")
assert_equal(caffeine._icons["off"], caffeine.menuBarItem._icon, "menubar item reset to inactive icon")

caffeine:stop()
assert_equal(nil, caffeine.steamTimer, "steamTimer cleaned up on stop()")

print(string.format("\n=========================================\nTest Results: %d Passed, %d Failed\n=========================================", passed, failed))
if failed > 0 then os.exit(1) end
