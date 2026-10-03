-- test_caffeine.lua: Unit tests for Caffeine.spoon
package.path = "Source/Caffeine.spoon/?.lua;" .. package.path

local passed = 0
local failed = 0

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    io.stderr:write(string.format("FAIL: %s (expected: %s, got: %s)\n", msg or "assertion failed", tostring(expected), tostring(actual)))
    failed = failed + 1
    error("test failed")
  else
    passed = passed + 1
  end
end

local function assert_true(condition, msg)
  if not condition then
    io.stderr:write(string.format("FAIL: %s (expected truthy, got: %s)\n", msg or "assertion failed", tostring(condition)))
    failed = failed + 1
    error("test failed")
  else
    passed = passed + 1
  end
end

-- Mock Hammerspoon environment
local mockCaffeinateState = { displayIdle = false }
local mockMenubar = {
  _icon = nil,
  _tooltip = nil,
  _clickCallback = nil,
  _deleted = false,
  new = function()
    local mb = {
      _icon = nil,
      _tooltip = nil,
      _clickCallback = nil,
      _deleted = false,
    }
    function mb:setIcon(icon) self._icon = icon return self end
    function mb:setTooltip(tip) self._tooltip = tip return self end
    function mb:setClickCallback(fn) self._clickCallback = fn return self end
    function mb:delete() self._deleted = true return self end
    return mb
  end
}

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

local mockImage = {
  imageFromPath = function(path)
    local img = { _path = path, _template = false }
    function img:template(val)
      if val ~= nil then self._template = val end
      return self._template
    end
    return img
  end
}

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

_G.hs = {
  caffeinate = {
    get = function(kind) return mockCaffeinateState[kind] end,
    set = function(kind, val) mockCaffeinateState[kind] = val end,
    toggle = function(kind)
      mockCaffeinateState[kind] = not mockCaffeinateState[kind]
      return mockCaffeinateState[kind]
    end,
    watcher = mockWatcher
  },
  menubar = mockMenubar,
  hotkey = mockHotkey,
  image = mockImage,
  spoons = {
    scriptPath = function() return "Source/Caffeine.spoon" end,
    bindHotkeysToSpec = function(def, mapping)
      _G.hs.spoons.lastBound = { def = def, mapping = mapping }
      if mapping and mapping.toggle then
        local hk = mockHotkey.new(mapping.toggle[1], mapping.toggle[2], def.toggle)
        hk:enable()
        return hk
      end
    end
  }
}

print("--- Running Caffeine.spoon Test Suite ---")

local caffeine = require("init")

-- [Test 1] Metadata & Path Initialization
print("\n[Test 1] Metadata & Path")
assert_equal("Caffeine", caffeine.name, "Spoon name is Caffeine")
assert_equal("1.2", caffeine.version, "Spoon version is 1.2")
assert_true(caffeine.spoonPath:match("Source/Caffeine%.spoon") ~= nil, "spoonPath resolved")

-- [Test 2] State Inspection (getState and isCaffeinated)
print("\n[Test 2] State Inspection")
mockCaffeinateState.displayIdle = false
assert_equal(false, caffeine:getState(), "getState returns false initially")
assert_equal(false, caffeine:isCaffeinated(), "isCaffeinated returns false initially")

mockCaffeinateState.displayIdle = true
assert_equal(true, caffeine:getState(), "getState returns true when displayIdle is true")
assert_equal(true, caffeine:isCaffeinated(), "isCaffeinated returns true when displayIdle is true")

-- [Test 3] setState when not started (Safety Check: No crash when menuBarItem is nil)
print("\n[Test 3] Safe setState when stopped")
assert_equal(nil, caffeine.menuBarItem, "menuBarItem is nil before start")
caffeine:setState(false)
assert_equal(false, caffeine:getState(), "setState(false) updated state without error")
caffeine:setState(true)
assert_equal(true, caffeine:getState(), "setState(true) updated state without error")

-- [Test 4] Lifecycle (start and stop)
print("\n[Test 4] Lifecycle")
caffeine:start()
assert_true(caffeine.menuBarItem ~= nil, "menuBarItem created on start")
assert_true(not caffeine.menuBarItem._deleted, "menuBarItem is active")
assert_true(caffeine.sleepWatcher ~= nil and caffeine.sleepWatcher._running, "sleepWatcher running")
assert_true(caffeine.menuBarItem._icon ~= nil, "icon assigned")
assert_true(caffeine.menuBarItem._icon._template == true, "icon template set to true")
assert_equal("Caffeine: Display sleep prevented", caffeine.menuBarItem._tooltip, "active tooltip set")

caffeine:stop()
assert_equal(nil, caffeine.menuBarItem, "menuBarItem cleaned up on stop")
assert_equal(nil, caffeine.sleepWatcher, "sleepWatcher cleaned up on stop")

-- [Test 5] clicked() with dot and colon syntax
print("\n[Test 5] clicked() toggling")
caffeine:start()
caffeine:setState(false)
assert_equal(false, caffeine:getState(), "caffeinate state is false")
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "inactive tooltip set")

-- Call with dot
caffeine.clicked()
assert_equal(true, caffeine:getState(), "caffeine.clicked() toggled state to true")
assert_equal("Caffeine: Display sleep prevented", caffeine.menuBarItem._tooltip, "tooltip updated to active")

-- Call with colon
caffeine:clicked()
assert_equal(false, caffeine:getState(), "caffeine:clicked() toggled state to false")
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "tooltip updated to inactive")

-- [Test 6] setDisplay() with dot and colon syntax
print("\n[Test 6] setDisplay() flexibility")
caffeine.setDisplay(true)
assert_equal("Caffeine: Display sleep prevented", caffeine.menuBarItem._tooltip, "setDisplay(true) via dot works")

caffeine:setDisplay(false)
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "setDisplay(false) via colon works")

-- [Test 7] Sleep/Wake Watcher Event
print("\n[Test 7] System Sleep/Wake Watcher")
mockCaffeinateState.displayIdle = true
caffeine.sleepWatcher._fn(mockWatcher.systemDidWake)
assert_equal("Caffeine: Display sleep prevented", caffeine.menuBarItem._tooltip, "systemDidWake resynced icon")

mockCaffeinateState.displayIdle = false
caffeine.sleepWatcher._fn(mockWatcher.screensDidWake)
assert_equal("Caffeine: Sleep allowed", caffeine.menuBarItem._tooltip, "screensDidWake resynced icon")

-- [Test 8] Hotkeys binding
print("\n[Test 8] Hotkey Bindings")
caffeine:bindHotkeys({ toggle = { {"cmd", "alt"}, "c" } })
assert_true(_G.hs.spoons.lastBound ~= nil, "hs.spoons.bindHotkeysToSpec was invoked")
assert_equal("table", type(_G.hs.spoons.lastBound.def), "def table created")
assert_equal("function", type(_G.hs.spoons.lastBound.def.toggle), "toggle function defined")

-- Test invoking the hotkey action
caffeine:setState(false)
_G.hs.spoons.lastBound.def.toggle()
assert_equal(true, caffeine:getState(), "hotkey toggle action toggled state")

caffeine:stop()

-- [Test 9] Icon Caching Optimization
print("\n[Test 9] Icon Caching")
assert_true(caffeine._icons ~= nil, "icon cache initialized")
assert_true(caffeine._icons["on"] ~= nil, "on icon cached")
assert_true(caffeine._icons["off"] ~= nil, "off icon cached")
caffeine:start()
local cachedOn = caffeine._icons["on"]
caffeine:setDisplay(true)
assert_equal(cachedOn, caffeine.menuBarItem._icon, "menuBarItem reuses cached icon object without disk reload")
caffeine:stop()

print(string.format("\n=========================================\nTest Results: %d Passed, %d Failed\n=========================================", passed, failed))
if failed > 0 then os.exit(1) end
