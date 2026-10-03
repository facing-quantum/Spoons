--- === Caffeine ===
---
--- Prevent the screen from going to sleep
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Caffeine.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Caffeine.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Caffeine"
obj.version = "1.2"
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

-- Internal helper to locate Spoon directory
local function script_path()
    local sp = hs and hs.spoons and hs.spoons.scriptPath
    if sp then return sp() end
    local src = debug.getinfo(2, "S").source:sub(2)
    return src:match("(.*/)") or "./"
end

--- Caffeine.spoonPath
--- Variable
--- The file path to the Spoon directory.
obj.spoonPath = script_path()

-- Cached template icons to avoid repeated disk reads and PDF parsing on clicks
local function getIcon(self, state)
    self._icons = self._icons or {}
    local key = state and "on" or "off"
    if not self._icons[key] then
        local path = (self.spoonPath or "") .. (state and "/caffeine-on.pdf" or "/caffeine-off.pdf")
        local img = hs and hs.image and hs.image.imageFromPath and hs.image.imageFromPath(path)
        if img and img.template then img:template(true) end
        self._icons[key] = img or path
    end
    return self._icons[key]
end

--- Caffeine:init()
--- Method
--- Initializes the Spoon.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Caffeine object
function obj:init()
    return self
end

--- Caffeine:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for Caffeine.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---   * toggle - This will toggle the state of display sleep prevention, and update the menubar graphic
---
--- Returns:
---  * The Caffeine object
function obj:bindHotkeys(mapping)
    local def = { toggle = function() self:clicked() end }
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
--- Returns whether or not screen sleep prevention is currently active.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A boolean, true if display sleep prevention is active, false otherwise
function obj:getState()
    return (hs and hs.caffeinate and hs.caffeinate.get and hs.caffeinate.get("displayIdle")) == true
end

--- Caffeine:isCaffeinated()
--- Method
--- Alias of `Caffeine:getState()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A boolean, true if display sleep prevention is active, false otherwise
function obj:isCaffeinated()
    return self:getState()
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

    self.menuBarItem:setIcon(getIcon(self, state))
    if self.menuBarItem.setTooltip then
        self.menuBarItem:setTooltip(state and "Caffeine: Display sleep prevented" or "Caffeine: Sleep allowed")
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
    local newState = hs and hs.caffeinate and hs.caffeinate.toggle and hs.caffeinate.toggle("displayIdle")
    target:setDisplay(newState)
end

--- Caffeine:setState(on)
--- Method
--- Sets whether or not caffeination should be enabled.
---
--- Parameters:
---  * on - A boolean, true if screens should be kept awake, false to let macOS send them to sleep
---
--- Returns:
---  * The Caffeine object
function obj:setState(on)
    if hs and hs.caffeinate and hs.caffeinate.set then
        hs.caffeinate.set("displayIdle", on)
    end
    return self:setDisplay(on)
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
    self.menuBarItem:setClickCallback(function() self:clicked() end)

    if self.hotkeyToggle then self.hotkeyToggle:enable() end

    if hs and hs.caffeinate and hs.caffeinate.watcher then
        self.sleepWatcher = hs.caffeinate.watcher.new(function(event)
            local w = hs.caffeinate.watcher
            if event == w.systemDidWake or event == w.screensDidWake then
                self:setDisplay(self:getState())
            end
        end):start()
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
    if self.menuBarItem then
        self.menuBarItem:delete()
        self.menuBarItem = nil
    end
    if self.hotkeyToggle then self.hotkeyToggle:disable() end
    if self.sleepWatcher then
        self.sleepWatcher:stop()
        self.sleepWatcher = nil
    end
    return self
end

return obj
