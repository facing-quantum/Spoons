--- === WifiNotifier ===
---
--- Receive notifications every time your wifi network changes.
---
--- Download: https://github.com/Hammerspoon/Spoons/raw/master/Spoons/WifiNotifier.spoon.zip


local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WifiNotifier"
obj.version = "1.1"
obj.author = "Garth Mortensen"
obj.homepage = "https://github.com/Hammerspoon/spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- WifiNotifier:init()
--- Method
--- Initialize the WifiNotifier spoon
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WifiNotifier object
function obj:init()
    self.wifiNotifier = hs.wifi.watcher.new(function() self:ssidChangedCallback() end)
    self.lastSSID = hs.wifi.currentNetwork()
    return self
end

--- WifiNotifier:start()
--- Method
--- Starts the wifiNotifier
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WifiNotifier object
function obj:start()
    self.wifiNotifier:start()
    return self
end

--- WifiNotifier:ssidChangedCallback()
--- Method
--- Fires whenever the wifiWatcher detects an SSID change.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WifiNotifier object
function obj:ssidChangedCallback()
    local newSSID = hs.wifi.currentNetwork()
    if newSSID == self.lastSSID then return end

    if newSSID == nil then
        hs.notify.new({title="Wifi disconnected", informativeText="Left " .. self.lastSSID}):send()
    elseif self.lastSSID == nil then
        hs.notify.new({title="Wifi connected", informativeText="Joined " .. newSSID}):send()
    else
        hs.notify.new({title="Network Change", informativeText="Left " .. self.lastSSID .. ". Joined " .. newSSID}):send()
    end

    self.lastSSID = newSSID
end

return obj
