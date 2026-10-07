--- === Caffeine ===
---
--- Prevent the screen from going to sleep
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Caffeine.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Caffeine.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Caffeine"
obj.version = "1.5"
obj.author = "Chris Jones <cmsj@tenshu.net>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- Caffeine.menuBarItem
--- Variable
--- The `hs.menubar` item for Caffeine.
obj.menuBarItem = nil

--- Caffeine.hotkeyToggle
--- Variable
--- The `hs.hotkey` object for toggling Caffeine, if bound directly.
obj.hotkeyToggle = nil

--- Caffeine.sleepWatcher
--- Variable
--- The `hs.caffeinate.watcher` used to resynchronize the menubar icon across system sleep/wake events.
obj.sleepWatcher = nil

--- Caffeine.batteryWatcher
--- Variable
--- The `hs.battery.watcher` used to automatically deactivate Caffeine when switching to battery power.
obj.batteryWatcher = nil

--- Caffeine.rightClickTap
--- Variable
--- The `hs.eventtap` used to detect secondary (right) clicks on the menubar item to display the context menu.
obj.rightClickTap = nil

--- Caffeine.preventType
--- Variable
--- The type of sleep prevention to enforce. Defaults to `"displayIdle"` (keeps screen and system awake).
--- Can also be set to `"systemIdle"` (allows screen sleep while keeping system awake for downloads, renders, etc.).
obj.preventType = "displayIdle"

--- Caffeine.disableOnBattery
--- Variable
--- Boolean indicating whether Caffeine should automatically deactivate when the computer is running on battery power. Defaults to `false`.
obj.disableOnBattery = false

--- Caffeine.menuOnLeftClick
--- Variable
--- Boolean indicating whether left-clicking the menubar icon displays the dropdown menu (`true`) or directly toggles state (`false`).
--- Defaults to `false` (direct 1-click toggle on all macOS versions; modifier-click or right-click opens the context menu).
obj.menuOnLeftClick = false

--- Caffeine.sessionTimer
--- Variable
--- The `hs.timer` object managing timed caffeination sessions.
obj.sessionTimer = nil

--- Caffeine.sessionEndTime
--- Variable
--- Unix timestamp representing the scheduled end time of the active timed caffeination session, or `nil` if indefinite/off.
obj.sessionEndTime = nil

--- Caffeine.animateSteam
--- Variable
--- Boolean indicating whether to animate the steam rising from the cup when Caffeine is active. Defaults to `true`.
obj.animateSteam = true

--- Caffeine.steamTimer
--- Variable
--- The `hs.timer` object managing the steam animation loop when active.
obj.steamTimer = nil

-- Raw base coordinates for the two authentic steam plumes (prior to dy offset)
local RAW_PLUME_1 = {
    { x = 4.66, y = 0.59 },
    { c1x = 5.16, c1y = 0.59, c2x = 5.62, c2y = 0.58, x = 6.08, y = 0.59 },
    { c1x = 6.13, c1y = 0.59, c2x = 6.19, c2y = 0.63, x = 6.23, y = 0.66 },
    { c1x = 6.75, c1y = 1.05, c2x = 6.89, c2y = 1.54, x = 6.60, y = 2.13 },
    { c1x = 6.44, c1y = 2.45, c2x = 6.22, c2y = 2.73, x = 6.03, y = 3.04 },
    { c1x = 5.88, c1y = 3.29, c2x = 5.72, c2y = 3.54, x = 5.61, y = 3.81 },
    { c1x = 5.42, c1y = 4.29, c2x = 5.54, c2y = 4.69, x = 5.92, y = 5.03 },
    { c1x = 5.97, c1y = 5.07, c2x = 6.02, c2y = 5.12, x = 6.10, y = 5.19 },
    { c1x = 5.59, c1y = 5.19, c2x = 5.12, c2y = 5.25, x = 4.67, y = 5.17 },
    { c1x = 4.34, c1y = 5.11, c2x = 4.11, c2y = 4.79, x = 4.05, y = 4.45 },
    { c1x = 4.01, c1y = 4.24, c2x = 4.03, c2y = 3.98, x = 4.11, y = 3.78 },
    { c1x = 4.26, c1y = 3.44, c2x = 4.48, c2y = 3.14, x = 4.67, y = 2.82 },
    { c1x = 4.81, c1y = 2.59, c2x = 4.96, c2y = 2.37, x = 5.08, y = 2.13 },
    { c1x = 5.36, c1y = 1.55, c2x = 5.27, c2y = 1.14, x = 4.80, y = 0.71 },
    { c1x = 4.76, c1y = 0.68, c2x = 4.73, c2y = 0.65, x = 4.66, y = 0.59 }
}

local RAW_PLUME_2 = {
    { x = 7.74, y = 0.59 },
    { c1x = 8.25, c1y = 0.59, c2x = 8.71, c2y = 0.58, x = 9.18, y = 0.59 },
    { c1x = 9.25, c1y = 0.59, c2x = 9.33, c2y = 0.67, x = 9.39, y = 0.72 },
    { c1x = 9.84, c1y = 1.09, c2x = 9.96, c2y = 1.55, x = 9.71, y = 2.07 },
    { c1x = 9.54, c1y = 2.40, c2x = 9.32, c2y = 2.70, x = 9.13, y = 3.02 },
    { c1x = 8.98, c1y = 3.27, c2x = 8.81, c2y = 3.51, x = 8.71, y = 3.78 },
    { c1x = 8.50, c1y = 4.27, c2x = 8.62, c2y = 4.68, x = 9.02, y = 5.04 },
    { c1x = 9.06, c1y = 5.08, c2x = 9.11, c2y = 5.12, x = 9.18, y = 5.19 },
    { c1x = 8.68, c1y = 5.19, c2x = 8.20, c2y = 5.25, x = 7.75, y = 5.17 },
    { c1x = 7.42, c1y = 5.11, c2x = 7.20, c2y = 4.79, x = 7.13, y = 4.45 },
    { c1x = 7.09, c1y = 4.24, c2x = 7.11, c2y = 3.98, x = 7.20, y = 3.78 },
    { c1x = 7.34, c1y = 3.45, c2x = 7.56, c2y = 3.14, x = 7.75, y = 2.82 },
    { c1x = 7.89, c1y = 2.59, c2x = 8.05, c2y = 2.37, x = 8.16, y = 2.13 },
    { c1x = 8.44, c1y = 1.55, c2x = 8.35, c2y = 1.14, x = 7.88, y = 0.71 },
    { c1x = 7.85, c1y = 0.68, c2x = 7.81, c2y = 0.65, x = 7.74, y = 0.59 }
}

-- Returns the menubar item's frame in Hammerspoon (top-left origin) coordinates.
-- hs.menubar:frame() flips the raw Cocoa frame using hs.screen.mainScreen()
-- (the screen with keyboard focus), but Cocoa coordinates are relative to the
-- *primary* screen. With displays of different heights (e.g. a 14" MacBook Pro
-- beside a lower-resolution primary monitor) the result is off by the height
-- difference, which can push the popup point off-screen so the menu never shows.
-- hs.menubar:popupMenu() flips back using the primary screen, so we must match it.
local function menubarItemFrame(mb)
    if not mb then return nil end
    local primary = (hs and hs.screen and hs.screen.primaryScreen) and hs.screen.primaryScreen() or nil
    if mb._frame and primary and primary.fullFrame then
        local raw = mb:_frame()
        if not raw then return nil end
        local pf = primary:fullFrame()
        return { x = raw.x, y = pf.h - raw.y - raw.h, w = raw.w, h = raw.h }
    end
    return mb.frame and mb:frame() or nil
end

-- Calculate parametric wafting and vertical drift offset for steam animation frames
local function getPlumeOffset(plumeNum, frameIdx, y)
    if not frameIdx then return 0, 0 end
    -- h is 0 at steam base (y >= 5.2 near cup rim) and smoothly scales up to 1.0 at steam tip (y <= 0.6)
    local h = math.max(0, math.min(1, (5.2 - y) / 4.6))
    -- 4 cyclic frames: plume 1 and plume 2 waft 90 degrees out of phase for organic shimmer
    local phi = (frameIdx - 1) * (math.pi / 2)
    if plumeNum == 2 then
        phi = phi + (math.pi / 2)
    end
    local dx = h * 0.45 * math.sin(phi)
    local dy_offset = -h * 0.35 * math.abs(math.sin(phi))
    return dx, dy_offset
end

local function transformSteamCoords(rawCoords, plumeNum, frameIdx, dy)
    local res = {}
    for i, pt in ipairs(rawCoords) do
        local offX, offY = getPlumeOffset(plumeNum, frameIdx, pt.y)
        local newPt = {
            x = pt.x + offX,
            y = pt.y + dy + offY
        }
        if pt.c1x then
            local c1offX, c1offY = getPlumeOffset(plumeNum, frameIdx, pt.c1y)
            newPt.c1x = pt.c1x + c1offX
            newPt.c1y = pt.c1y + dy + c1offY
        end
        if pt.c2x then
            local c2offX, c2offY = getPlumeOffset(plumeNum, frameIdx, pt.c2y)
            newPt.c2x = pt.c2x + c2offX
            newPt.c2y = pt.c2y + dy + c2offY
        end
        res[i] = newPt
    end
    return res
end

-- Internal helper to draw the authentic Caffeine coffee cup icon programmatically via hs.canvas
local function drawCanvasIcon(state, frameIdx)
    if not (hs and hs.canvas and hs.canvas.new) then return nil end

    -- Both Active (ON) and Inactive (OFF) use an identical 16x22 canvas frame.
    -- Cup coordinates (y = 6.45 to 15.55) with dy = 1.5 align the cup's vertical center
    -- and bottom baseline with neighboring macOS menubar status icons (e.g. Sound, Time Machine).
    -- Because dimensions and coordinates are identical across states, the cup never shifts when toggled.
    local cw = 16
    local ch = 22
    local dy = 1.5

    local c = hs.canvas.new({ x = 0, y = 0, w = cw, h = ch })
    if not c then return nil end

    local color = { black = 1, alpha = 0.95 }

    -- 1. Outer cup contour and integrated handle (from original Adobe Illustrator artwork)
    c:appendElements({
        type = "segments",
        action = "fill",
        fillColor = color,
        closed = true,
        coordinates = {
            { x = -0.01, y = 6.45 + dy },
            { c1x = 0.53, c1y = 6.45 + dy, c2x = 1.05, c2y = 6.45 + dy, x = 1.57, y = 6.45 + dy },
            { c1x = 5.39, c1y = 6.45 + dy, c2x = 9.21, c2y = 6.45 + dy, x = 13.03, y = 6.45 + dy },
            { c1x = 13.72, c1y = 6.45 + dy, c2x = 14.38, c2y = 6.58 + dy, x = 14.95, y = 7.00 + dy },
            { c1x = 16.54, c1y = 8.17 + dy, c2x = 16.27, c2y = 10.59 + dy, x = 14.47, y = 11.40 + dy },
            { c1x = 14.06, c1y = 11.58 + dy, c2x = 13.63, c2y = 11.65 + dy, x = 13.18, y = 11.67 + dy },
            { c1x = 12.89, c1y = 11.68 + dy, c2x = 12.59, c2y = 11.68 + dy, x = 12.30, y = 11.67 + dy },
            { c1x = 12.12, c1y = 11.66 + dy, c2x = 12.04, c2y = 11.71 + dy, x = 11.98, y = 11.88 + dy },
            { c1x = 11.72, c1y = 12.65 + dy, c2x = 11.35, c2y = 13.37 + dy, x = 10.81, y = 13.99 + dy },
            { c1x = 10.07, c1y = 14.85 + dy, c2x = 9.12, c2y = 15.36 + dy, x = 8.01, y = 15.55 + dy },
            { c1x = 6.76, c1y = 15.76 + dy, c2x = 5.50, c2y = 15.75 + dy, x = 4.28, y = 15.39 + dy },
            { c1x = 2.99, c1y = 15.01 + dy, c2x = 2.07, c2y = 14.17 + dy, x = 1.44, y = 13.00 + dy },
            { c1x = 0.93, c1y = 12.08 + dy, c2x = 0.66, c2y = 11.08 + dy, x = 0.46, y = 10.06 + dy },
            { c1x = 0.22, c1y = 8.88 + dy, c2x = 0.07, c2y = 7.68 + dy, x = -0.01, y = 6.45 + dy }
        }
    })

    -- 2. Inner cup cutout (hollow bowl)
    c:appendElements({
        type = "segments",
        action = "fill",
        compositeRule = "clear",
        closed = true,
        coordinates = {
            { x = 1.65, y = 7.98 + dy },
            { c1x = 1.69, c1y = 8.28 + dy, c2x = 1.73, c2y = 8.57 + dy, x = 1.78, y = 8.86 + dy },
            { c1x = 1.94, c1y = 9.84 + dy, c2x = 2.13, c2y = 10.81 + dy, x = 2.51, y = 11.74 + dy },
            { c1x = 2.99, c1y = 12.94 + dy, c2x = 3.78, c2y = 13.80 + dy, x = 5.09, y = 14.06 + dy },
            { c1x = 5.82, c1y = 14.20 + dy, c2x = 6.55, c2y = 14.21 + dy, x = 7.28, y = 14.14 + dy },
            { c1x = 7.85, c1y = 14.09 + dy, c2x = 8.40, c2y = 13.96 + dy, x = 8.90, y = 13.66 + dy },
            { c1x = 9.62, c1y = 13.23 + dy, c2x = 10.06, c2y = 12.58 + dy, x = 10.38, y = 11.84 + dy },
            { c1x = 10.83, c1y = 10.80 + dy, c2x = 11.02, c2y = 9.70 + dy, x = 11.19, y = 8.60 + dy },
            { c1x = 11.22, c1y = 8.40 + dy, c2x = 11.25, c2y = 8.19 + dy, x = 11.27, y = 7.98 + dy }
        }
    })

    -- 3. Handle hole cutout
    c:appendElements({
        type = "segments",
        action = "fill",
        compositeRule = "clear",
        closed = true,
        coordinates = {
            { x = 12.47, y = 10.14 + dy },
            { c1x = 12.80, c1y = 10.14 + dy, c2x = 13.10, c2y = 10.17 + dy, x = 13.40, y = 10.13 + dy },
            { c1x = 13.61, c1y = 10.11 + dy, c2x = 13.83, c2y = 10.03 + dy, x = 14.01, y = 9.92 + dy },
            { c1x = 14.64, c1y = 9.54 + dy, c2x = 14.64, c2y = 8.59 + dy, x = 14.01, y = 8.19 + dy },
            { c1x = 13.64, c1y = 7.96 + dy, c2x = 13.23, c2y = 7.95 + dy, x = 12.82, y = 7.98 + dy },
            { c1x = 12.70, c1y = 8.71 + dy, c2x = 12.59, c2y = 9.41 + dy, x = 12.47, y = 10.14 + dy }
        }
    })

    if state then
        -- Active (ON): Fill coffee inside the cup
        c:appendElements({
            type = "rectangle",
            action = "fill",
            fillColor = color,
            frame = { x = 1.66, y = 9.06 + dy, w = 9.63, h = 3.74 }
        })
        c:appendElements({
            type = "rectangle",
            action = "fill",
            fillColor = color,
            frame = { x = 2.80, y = 12.38 + dy, w = 7.56, h = 1.81 }
        })

        -- Steam plume 1 (Left)
        c:appendElements({
            type = "segments",
            action = "fill",
            fillColor = color,
            closed = true,
            coordinates = transformSteamCoords(RAW_PLUME_1, 1, frameIdx, dy)
        })

        -- Steam plume 2 (Right)
        c:appendElements({
            type = "segments",
            action = "fill",
            fillColor = color,
            closed = true,
            coordinates = transformSteamCoords(RAW_PLUME_2, 2, frameIdx, dy)
        })
    end

    local img = c:imageFromCanvas()
    if img and img.template then
        img:template(true)
    end
    c:delete()
    return img
end

-- Fallback ASCII representation if hs.canvas is unavailable
local function drawAsciiIcon(state)
    if not (hs and hs.image and hs.image.imageFromASCII) then return nil end
    local ascii
    if state then
        ascii = [[
....*...*.........
...*...*..........
....*...*.........
..................
..************....
..*..........*..*.
..*..........*.*.*
..*..........*.*.*
..*..........*..*.
..*..........*....
...*........*.....
....********......
.****************.
..................
]]
    else
        ascii = [[
..................
..................
..************....
..*..........*..*.
..*..........*.*.*
..*..........*.*.*
..*..........*..*.
..*..........*....
...*........*.....
....********......
.****************.
..................
..................
..................
]]
    end
    local img = hs.image.imageFromASCII(ascii)
    if img and img.template then img:template(true) end
    return img
end

-- Load and cache the authentic Caffeine template icons generated via hs.canvas
local function getIcon(self, state)
    self._icons = self._icons or {}
    local key = state and "on" or "off"
    if not self._icons[key] then
        self._icons["on"]  = self._icons["on"]  or (drawCanvasIcon(true)  or drawAsciiIcon(true))
        self._icons["off"] = self._icons["off"] or (drawCanvasIcon(false) or drawAsciiIcon(false))
    end
    return self._icons[key]
end

-- Pre-generate and cache the cyclic steam animation frames
local function getSteamFrames(self)
    if self._steamFrames then return self._steamFrames end
    self._steamFrames = {}
    for i = 1, 4 do
        local img = drawCanvasIcon(true, i)
        if img then
            table.insert(self._steamFrames, img)
        end
    end
    if #self._steamFrames == 0 then
        local fallback = getIcon(self, true)
        if fallback then
            table.insert(self._steamFrames, fallback)
        end
    end
    return self._steamFrames
end

-- Internal helper to detect host macOS / Darwin major version
local function getOSMajorVersion()
    if hs and hs.host and hs.host.operatingSystemVersion then
        local ver = hs.host.operatingSystemVersion()
        if ver and ver.major then
            -- If already major >= 20 (e.g. Darwin 26/27 or testing mock)
            if ver.major >= 20 then
                return ver.major
            -- macOS 11+ maps to Darwin major version (macOS 11 = Darwin 20, macOS 17 = 26, macOS 18 = 27)
            elseif ver.major >= 11 then
                return ver.major + 9
            end
            return ver.major
        end
    end

    -- Check Darwin kernel release via uname (e.g. Darwin 27.x or 26.x)
    local ok, out = pcall(function()
        local h = io.popen("uname -s -r 2>/dev/null")
        if h then
            local str = h:read("*a")
            h:close()
            return str
        end
    end)
    if ok and out and out:match("^Darwin") then
        local darwinMajor = tonumber(out:match("Darwin%s+(%d+)"))
        if darwinMajor and darwinMajor > 0 then
            return darwinMajor
        end
    end

    return nil
end

--- Caffeine:init()
--- Method
--- Initializes the Spoon and restores any previously persisted user preferences.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Caffeine object
function obj:init()
    if hs and hs.settings and hs.settings.get then
        local savedDisable = hs.settings.get("Caffeine.disableOnBattery")
        if savedDisable ~= nil then
            self.disableOnBattery = (savedDisable == true)
        end
        local savedPrevent = hs.settings.get("Caffeine.preventType")
        if savedPrevent ~= nil and (savedPrevent == "displayIdle" or savedPrevent == "systemIdle") then
            self.preventType = savedPrevent
        end
        local savedAnimate = hs.settings.get("Caffeine.animateSteam")
        if savedAnimate ~= nil then
            self.animateSteam = (savedAnimate == true)
        end
        -- Clear any stale menuOnLeftClick in hs.settings so it never overrides 1-click toggle
        if hs.settings.clear then
            hs.settings.clear("Caffeine.menuOnLeftClick")
        end
    end

    -- Direct 1-click toggle by default on all macOS versions:
    -- On macOS 27+: Right-click or modifier-click opens the context menu.
    -- On macOS 26: Modifier-click (Option ⌥ + click or Cmd ⌘ + click) opens the context menu.
    self.menuOnLeftClick = false

    return self
end

--- Caffeine:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for Caffeine.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---   * toggle - This will toggle the state of sleep prevention, and update the menubar graphic
---   * menu - Open the right-click duration and settings popup menu
---
--- Returns:
---  * The Caffeine object
function obj:bindHotkeys(mapping)
    local def = {
        toggle = function() self:clicked() end,
        menu = function() self:popupMenu() end
    }
    if hs and hs.spoons and hs.spoons.bindHotkeysToSpec then
        hs.spoons.bindHotkeysToSpec(def, mapping)
    elseif mapping and mapping["toggle"] then
        if self.hotkeyToggle then self.hotkeyToggle:delete() end
        self.hotkeyToggle = hs.hotkey.new(mapping["toggle"][1], mapping["toggle"][2], def.toggle)
        if self.menuBarItem then self.hotkeyToggle:enable() end
    end
    return self
end

--- Caffeine:getState()
--- Method
--- Returns whether or not screen/system sleep prevention is currently active.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A boolean, true if sleep prevention is active, false otherwise
function obj:getState()
    local kind = self.preventType or "displayIdle"
    return (hs and hs.caffeinate and hs.caffeinate.get and hs.caffeinate.get(kind)) == true
end

--- Caffeine:isCaffeinated()
--- Method
--- Alias of `Caffeine:getState()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A boolean, true if sleep prevention is active, false otherwise
function obj:isCaffeinated()
    return self:getState()
end

--- Caffeine:setPreventType(preventType)
--- Method
--- Sets the sleep prevention type.
---
--- Parameters:
---  * preventType - A string, either `"displayIdle"` (default, screen & system sleep prevented) or `"systemIdle"` (system sleep prevented, screen allowed to sleep).
---
--- Returns:
---  * The Caffeine object
function obj:setPreventType(preventType)
    if preventType ~= "displayIdle" and preventType ~= "systemIdle" then
        preventType = "displayIdle"
    end
    local wasActive = self:getState()
    local oldType = self.preventType or "displayIdle"

    if wasActive and hs and hs.caffeinate and hs.caffeinate.set then
        hs.caffeinate.set(oldType, false)
        hs.caffeinate.set(preventType, true)
    end

    self.preventType = preventType
    if hs and hs.settings and hs.settings.set then
        hs.settings.set("Caffeine.preventType", self.preventType)
    end
    self:setDisplay(wasActive)
    return self
end

--- Caffeine:setDisableOnBattery(enabled)
--- Method
--- Enables or disables automatic deactivation when running on battery power and persists the preference.
---
--- Parameters:
---  * enabled - A boolean, true to automatically disable Caffeine on battery, false to allow battery caffeination.
---
--- Returns:
---  * The Caffeine object
function obj:setDisableOnBattery(enabled)
    self.disableOnBattery = (enabled == true)
    if hs and hs.settings and hs.settings.set then
        hs.settings.set("Caffeine.disableOnBattery", self.disableOnBattery)
    end
    if self.disableOnBattery and self:getState() and hs and hs.battery and hs.battery.powerSource then
        if hs.battery.powerSource() == "Battery Power" then
            self:setState(false)
        end
    end
    return self
end

--- Caffeine:setMenuOnLeftClick(enabled)
--- Method
--- Sets whether left-clicking the menubar icon displays the dropdown menu or directly toggles state.
---
--- Parameters:
---  * enabled - A boolean, true to open the dropdown menu on left click, false to directly toggle.
---
--- Returns:
---  * The Caffeine object
function obj:setMenuOnLeftClick(enabled)
    self.menuOnLeftClick = (enabled == true)
    if hs and hs.settings and hs.settings.set then
        hs.settings.set("Caffeine.menuOnLeftClick", self.menuOnLeftClick)
    end
    if self.menuBarItem then
        if self.menuOnLeftClick then
            if self.menuBarItem.setClickCallback then self.menuBarItem:setClickCallback(nil) end
            if self.menuBarItem.setMenu then
                self.menuBarItem:setMenu(function() return self:getMenuTable() end)
            end
        else
            if self.menuBarItem.setMenu then self.menuBarItem:setMenu(nil) end
            if self.menuBarItem.setClickCallback then
                self.menuBarItem:setClickCallback(function(mods)
                    self:_handleClick(mods)
                end)
            end
        end
    end
    return self
end

--- Caffeine:setAnimateSteam(enabled)
--- Method
--- Enables or disables the animated steam effect when Caffeine is active and persists the preference.
---
--- Parameters:
---  * enabled - A boolean, true to animate steam when active, false for static icon.
---
--- Returns:
---  * The Caffeine object
function obj:setAnimateSteam(enabled)
    self.animateSteam = (enabled == true)
    if hs and hs.settings and hs.settings.set then
        hs.settings.set("Caffeine.animateSteam", self.animateSteam)
    end
    if self.menuBarItem and self:getState() then
        self:setDisplay(true)
    end
    return self
end

function obj:_startSteamAnimation()
    if not self.animateSteam or self.steamTimer or not self.menuBarItem then return end
    local frames = getSteamFrames(self)
    if not frames or #frames <= 1 then return end

    local currentFrame = 1
    self.menuBarItem:setIcon(frames[currentFrame])

    if hs and hs.timer and hs.timer.doEvery then
        self.steamTimer = hs.timer.doEvery(0.25, function()
            if not self.menuBarItem or not self:getState() then
                self:_stopSteamAnimation()
                return
            end
            currentFrame = (currentFrame % #frames) + 1
            self.menuBarItem:setIcon(frames[currentFrame])
        end)
    end
end

function obj:_stopSteamAnimation()
    if self.steamTimer then
        self.steamTimer:stop()
        self.steamTimer = nil
    end
end

--- Caffeine:setDisplay(state)
--- Method
--- Updates the menubar icon and tooltip to match the given state.
---
--- Parameters:
---  * state - A boolean, true for active (caffeinated), false for inactive
---
--- Returns:
---  * The Caffeine object
function obj.setDisplay(self, state)
    -- Support both obj:setDisplay(state) and legacy obj.setDisplay(state)
    if self ~= obj and type(self) ~= "table" then
        state, self = self, obj
    end
    if not self.menuBarItem then return self end

    if state then
        local icon = getIcon(self, true)
        if icon then
            self.menuBarItem:setIcon(icon)
        end
        if self.animateSteam then
            self:_startSteamAnimation()
        else
            self:_stopSteamAnimation()
        end
    else
        self:_stopSteamAnimation()
        local icon = getIcon(self, false)
        if icon then
            self.menuBarItem:setIcon(icon)
        end
    end

    if self.menuBarItem.setTooltip then
        local tip = "Caffeine: "
        if state then
            local modeDesc = (self.preventType == "systemIdle") and "System sleep prevented" or "Display sleep prevented"
            if self.sessionEndTime then
                local remainingSec = math.max(0, self.sessionEndTime - os.time())
                local remainingMin = math.ceil(remainingSec / 60)
                tip = tip .. modeDesc .. " (" .. tostring(remainingMin) .. "m remaining)"
            else
                tip = tip .. modeDesc
            end
        else
            tip = tip .. "Sleep allowed"
        end
        self.menuBarItem:setTooltip(tip)
    end
    return self
end

--- Caffeine:clicked()
--- Method
--- Toggles caffeination state and updates the menubar icon.
---
--- Parameters:
---  * None
---
--- Returns:
---  * None
function obj.clicked(self)
    local target = (type(self) == "table" and self.name == obj.name) and self or obj
    local isCurrentlyActive = target:getState()
    target:setState(not isCurrentlyActive)
end

--- Caffeine:_handleClick(mods)
--- Method
--- Internal click handler differentiating left-click toggle vs modifier/secondary click for menu.
---
--- Parameters:
---  * mods - A table of modifiers passed by hs.menubar click callback (or nil)
---
--- Returns:
---  * None
function obj:_handleClick(mods)
    local hasMod = false

    -- Check modifiers table passed directly to click callback
    if type(mods) == "table" then
        if mods.cmd or mods.alt or mods.ctrl or mods.shift or mods.fn then
            hasMod = true
        end
    end

    -- Fallback: Check instantaneous keyboard modifier state via hs.eventtap
    if not hasMod and hs and hs.eventtap and hs.eventtap.checkKeyboardModifiers then
        local kmods = hs.eventtap.checkKeyboardModifiers(true)
        if type(kmods) == "table" then
            if kmods.cmd or kmods.alt or kmods.ctrl or kmods.shift or kmods.fn then
                hasMod = true
            elseif type(kmods._raw) == "number" and bit and bit.band and bit.band(kmods._raw, 0x1E0000) ~= 0 then
                hasMod = true
            end
        end
    end

    -- Fallback: Check if right or middle mouse button was pressed
    if not hasMod and hs and hs.mouse and hs.mouse.getButtons then
        local btns = hs.mouse.getButtons()
        if type(btns) == "table" and (btns.right or btns[2] or btns.middle or btns[3]) then
            hasMod = true
        end
    end

    if hasMod then
        self:popupMenu()
    else
        self:clicked()
    end
end

--- Caffeine:setState(on)
--- Method
--- Sets whether or not caffeination should be enabled indefinitely.
---
--- Parameters:
---  * on - A boolean, true if sleep should be prevented, false to let macOS sleep
---
--- Returns:
---  * The Caffeine object
function obj:setState(on)
    -- Clear any existing timer
    if self.sessionTimer then
        self.sessionTimer:stop()
        self.sessionTimer = nil
    end
    self.sessionEndTime = nil

    if on and self.disableOnBattery and hs and hs.battery and hs.battery.powerSource then
        if hs.battery.powerSource() == "Battery Power" then
            on = false
        end
    end

    local kind = self.preventType or "displayIdle"
    if hs and hs.caffeinate and hs.caffeinate.set then
        hs.caffeinate.set(kind, on)
        if not on and kind ~= "displayIdle" then
            hs.caffeinate.set("displayIdle", false)
        end
    end

    return self:setDisplay(on)
end

--- Caffeine:startTimed(minutes)
--- Method
--- Keeps macOS awake for a specified duration in minutes, then automatically returns to sleep allowed.
---
--- Parameters:
---  * minutes - Number of minutes to remain active (e.g. 15, 30, 60, 120)
---
--- Returns:
---  * The Caffeine object
function obj:startTimed(minutes)
    if not minutes or minutes <= 0 then
        return self:setState(false)
    end

    -- Clear existing timer
    if self.sessionTimer then
        self.sessionTimer:stop()
        self.sessionTimer = nil
    end

    self.sessionEndTime = os.time() + (minutes * 60)

    -- Activate caffeination
    local kind = self.preventType or "displayIdle"
    if hs and hs.caffeinate and hs.caffeinate.set then
        hs.caffeinate.set(kind, true)
    end

    self:setDisplay(true)

    -- Schedule expiration
    if hs and hs.timer and hs.timer.doAfter then
        self.sessionTimer = hs.timer.doAfter(minutes * 60, function()
            self.sessionTimer = nil
            self.sessionEndTime = nil
            local curKind = self.preventType or "displayIdle"
            if hs and hs.caffeinate and hs.caffeinate.set then
                hs.caffeinate.set(curKind, false)
            end
            self:setDisplay(false)
        end)
    end

    return self
end

--- Caffeine:getMenuTable()
--- Method
--- Generates a table formatted for `hs.menubar:setMenu()` representing the context menu options.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table of menu items
function obj:getMenuTable()
    local isActive = self:getState()
    local statusTitle = "Status: Sleep allowed"
    if isActive then
        if self.sessionEndTime then
            local remMin = math.max(0, math.ceil((self.sessionEndTime - os.time()) / 60))
            statusTitle = "Status: Active (" .. tostring(remMin) .. "m remaining)"
        else
            statusTitle = "Status: Active (Indefinitely)"
        end
    end

    local isDisplay = (self.preventType ~= "systemIdle")

    local menu = {
        { title = statusTitle, disabled = true },
        { title = "-" },
        {
            title = isActive and "Toggle: Deactivate (Allow sleep)" or "Toggle: Activate (Keep awake)",
            fn = function() self:clicked() end
        },
        {
            title = "Active (Indefinitely)",
            checked = (isActive and self.sessionEndTime == nil),
            fn = function() self:setState(true) end
        },
        {
            title = "Active for 15 minutes",
            fn = function() self:startTimed(15) end
        },
        {
            title = "Active for 30 minutes",
            fn = function() self:startTimed(30) end
        },
        {
            title = "Active for 1 hour",
            fn = function() self:startTimed(60) end
        },
        {
            title = "Active for 2 hours",
            fn = function() self:startTimed(120) end
        },
        {
            title = "Deactivate (Sleep allowed)",
            disabled = not isActive,
            fn = function() self:setState(false) end
        },
        { title = "-" },
        {
            title = "Prevent Display Sleep",
            checked = isDisplay,
            fn = function() self:setPreventType("displayIdle") end
        },
        {
            title = "Prevent System Sleep Only",
            checked = not isDisplay,
            fn = function() self:setPreventType("systemIdle") end
        },
        { title = "-" },
        {
            title = "Deactivate on Battery Power",
            checked = self.disableOnBattery == true,
            fn = function() self:setDisableOnBattery(not self.disableOnBattery) end
        },
        {
            title = "Animate Steam When Active",
            checked = self.animateSteam == true,
            fn = function() self:setAnimateSteam(not self.animateSteam) end
        },
        {
            title = "Open Menu on Left Click",
            checked = self.menuOnLeftClick == true,
            fn = function() self:setMenuOnLeftClick(not self.menuOnLeftClick) end
        }
    }
    return menu
end

--- Caffeine:popupMenu()
--- Method
--- Displays the context menu with duration options and settings at the current cursor or menubar position.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Caffeine object
function obj:popupMenu()
    local menuTable = self:getMenuTable()
    local pos = nil

    -- Prefer positioning cleanly below the menubar item so the menu does not overlap the icon or cursor
    local f = menubarItemFrame(self.menuBarItem)
    if f and f.h and f.h > 0 then
        pos = {
            x = math.floor(f.x),
            y = math.floor(f.y + f.h + 4)
        }
    end

    if not pos and hs and hs.mouse then
        local getPos = hs.mouse.absolutePosition or hs.mouse.getAbsolutePosition
        if getPos then
            local m = getPos()
            if m then
                pos = { x = m.x, y = math.max(m.y + 18, 28) }
            end
        end
    end
    pos = pos or { x = 400, y = 28 }

    -- Tier 1: Native Cocoa popup menu via NSMenu (standard across macOS versions)
    if self.menuBarItem and self.menuBarItem.popupMenu then
        local ok = pcall(function()
            self.menuBarItem:setMenu(menuTable)
            self.menuBarItem:popupMenu(pos)
        end)
        if not self.menuOnLeftClick then
            if self.menuBarItem.setMenu then self.menuBarItem:setMenu(nil) end
            if self.menuBarItem.setClickCallback then
                self.menuBarItem:setClickCallback(function(mods)
                    self:_handleClick(mods)
                end)
            end
        end
        if ok then return self end
    end

    -- Tier 2: Universal menu presentation for macOS 26 (and environments where Cocoa popupMenu is blocked):
    -- Uses hs.chooser to display all Caffeine options in an interactive floating palette.
    if hs and hs.chooser and hs.chooser.new then
        local choices = {}
        for _, item in ipairs(menuTable) do
            if item.title and item.title ~= "-" and not item.disabled then
                table.insert(choices, {
                    text = item.title .. (item.checked and " ✓" or ""),
                    subText = "Caffeine Option",
                    _fn = item.fn
                })
            end
        end
        self._chooser = hs.chooser.new(function(selected)
            if selected and selected._fn then
                selected._fn()
            end
            self._chooser = nil
        end)
        self._chooser:choices(choices)
        self._chooser:placeholderText("Caffeine Menu")
        pcall(function() self._chooser:show() end)
    end

    return self
end

--- Caffeine:start()
--- Method
--- Starts Caffeine.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Caffeine object
function obj:start()
    if self.menuBarItem then self:stop() end
    self.menuBarItem = hs.menubar.new()

    -- On macOS, attaching via setMenu provides native AppKit dropdown behavior on left-click
    if self.menuOnLeftClick then
        if self.menuBarItem.setMenu then
            self.menuBarItem:setMenu(function() return self:getMenuTable() end)
        end
    else
        self.menuBarItem:setClickCallback(function(mods)
            self:_handleClick(mods)
        end)
    end

    if self.hotkeyToggle then self.hotkeyToggle:enable() end

    -- Watch system sleep/wake/power events to keep icon state synchronized
    if hs and hs.caffeinate and hs.caffeinate.watcher then
        self.sleepWatcher = hs.caffeinate.watcher.new(function(event)
            local w = hs.caffeinate.watcher
            if event == w.systemDidWake or event == w.screensDidWake then
                self:setDisplay(self:getState())
            elseif event == w.systemWillSleep or event == w.screensDidSleep then
                self:_stopSteamAnimation()
            end
        end):start()
    end

    -- Watch battery status if auto-deactivate on battery is enabled
    if hs and hs.battery and hs.battery.watcher then
        self.batteryWatcher = hs.battery.watcher.new(function()
            if self.disableOnBattery and self:getState() and hs.battery.powerSource then
                if hs.battery.powerSource() == "Battery Power" then
                    self:setState(false)
                end
            end
        end):start()
    end

    -- Right-click eventtap to show popup menu when right-clicking the menubar item
    if hs and hs.eventtap and hs.eventtap.new and hs.eventtap.event and hs.eventtap.event.types then
        local rightMouseDownType = hs.eventtap.event.types.rightMouseDown
        if rightMouseDownType then
            self.rightClickTap = hs.eventtap.new({ rightMouseDownType }, function(event)
                if not self.menuBarItem then return false end
                local mf = menubarItemFrame(self.menuBarItem)
                if not mf then return false end
                local getPos = hs.mouse and (hs.mouse.absolutePosition or hs.mouse.getAbsolutePosition)
                local loc = (event and event.location and event:location()) or (getPos and getPos()) or { x = 0, y = 0 }
                if loc.x >= (mf.x - 2) and loc.x <= (mf.x + mf.w + 2) and
                   loc.y >= (mf.y - 2) and loc.y <= (mf.y + mf.h + 2) then
                    self:popupMenu()
                    return true
                end
                return false
            end):start()
        end
    end

    return self:setDisplay(self:getState())
end

--- Caffeine:stop()
--- Method
--- Stops Caffeine.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Caffeine object
function obj:stop()
    self:_stopSteamAnimation()
    if self.sessionTimer then
        self.sessionTimer:stop()
        self.sessionTimer = nil
    end
    self.sessionEndTime = nil

    if self.menuBarItem then
        self.menuBarItem:delete()
        self.menuBarItem = nil
    end
    if self.hotkeyToggle then self.hotkeyToggle:disable() end
    if self.sleepWatcher then
        self.sleepWatcher:stop()
        self.sleepWatcher = nil
    end
    if self.batteryWatcher then
        self.batteryWatcher:stop()
        self.batteryWatcher = nil
    end
    if self.rightClickTap then
        self.rightClickTap:stop()
        self.rightClickTap = nil
    end
    return self
end

return obj
