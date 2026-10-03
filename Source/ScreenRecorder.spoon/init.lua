--- === ScreenRecorder ===
---
--- Record a selected area of the screen to .mov, and to an animated GIF when ffmpeg is installed
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/ScreenRecorder.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/ScreenRecorder.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ScreenRecorder"
obj.version = "1.0"
obj.author = "facing-quantum"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- ScreenRecorder.outputDir
--- Variable
--- Folder where recordings are saved. Defaults to `~/Desktop`.
obj.outputDir = os.getenv("HOME") .. "/Desktop"

--- ScreenRecorder.maxLengthChoices
--- Variable
--- Max recording lengths (seconds) offered in the menubar. `0` means no limit.
obj.maxLengthChoices = { 10, 30, 60, 0 }

--- ScreenRecorder.menuBarItem
--- Variable
--- The `hs.menubar` item, created by `ScreenRecorder:start()`.
obj.menuBarItem = nil

local SETTINGS_KEY = "ScreenRecorder.maxSeconds"
local DEFAULT_MAX_SECONDS = 30
local MIN_SELECTION_SIZE = 10
local BORDER_WIDTH = 3
local FFMPEG_CANDIDATES = { "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }
local GIF_FILTER = "fps=10,scale='min(800,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"

local function fileExists(path)
    return hs.fs.attributes(path) ~= nil
end

function obj._uniqueBaseName(dir, timestamp)
    local base = dir .. "/Capture-" .. timestamp
    local candidate = base
    local suffix = 1
    while fileExists(candidate .. ".mov") or fileExists(candidate .. ".gif") do
        suffix = suffix + 1
        candidate = base .. "-" .. suffix
    end
    return candidate
end

function obj._screencaptureArgs(rect, maxSeconds, movPath)
    local region = string.format("%d,%d,%d,%d", math.floor(rect.x), math.floor(rect.y), math.floor(rect.w), math.floor(rect.h))
    local args = { "-v", "-k", "-R", region }
    if maxSeconds > 0 then
        table.insert(args, "-V")
        table.insert(args, tostring(maxSeconds))
    end
    table.insert(args, movPath)
    return args
end

function obj._ffmpegArgs(movPath, gifPath)
    return { "-y", "-i", movPath, "-vf", GIF_FILTER, gifPath }
end

function obj._findFfmpeg()
    for _, path in ipairs(FFMPEG_CANDIDATES) do
        if fileExists(path) then return path end
    end
    local output, ok = hs.execute("command -v ffmpeg", true)
    if ok and output and output ~= "" then
        return (output:gsub("%s+$", ""))
    end
    return nil
end

--- ScreenRecorder:maxSeconds()
--- Method
--- Returns the configured max recording length in seconds (`0` means no limit).
function obj:maxSeconds()
    local seconds = hs.settings.get(SETTINGS_KEY)
    if seconds == nil then return DEFAULT_MAX_SECONDS end
    return seconds
end

--- ScreenRecorder:setMaxSeconds(seconds)
--- Method
--- Sets and persists the max recording length.
---
--- Parameters:
---  * seconds - Max length in seconds; `0` means no limit
function obj:setMaxSeconds(seconds)
    hs.settings.set(SETTINGS_KEY, seconds)
end

local function lengthLabel(seconds)
    if seconds == 0 then return "No limit" end
    return seconds .. " s"
end

function obj:_menuItems()
    local lengthMenu = {}
    for _, seconds in ipairs(self.maxLengthChoices) do
        table.insert(lengthMenu, {
            title = lengthLabel(seconds),
            checked = (seconds == self:maxSeconds()),
            fn = function() self:setMaxSeconds(seconds) end,
        })
    end
    return {
        { title = self._recording and "Stop Recording" or "Start Recording", fn = function() self:toggleRecording() end },
        { title = "Max Length", menu = lengthMenu },
        { title = "Open Output Folder", fn = function() hs.task.new("/usr/bin/open", nil, { self.outputDir }):start() end },
    }
end

function obj:_updateTitle()
    if not self.menuBarItem then return end
    if self._recording then
        local elapsed = os.time() - self._recording.startedAt
        self.menuBarItem:setTitle(hs.styledtext.new("● " .. elapsed .. "s", { color = { red = 1 } }))
    else
        self.menuBarItem:setTitle("◉")
    end
end

--- ScreenRecorder:start()
--- Method
--- Creates the menubar item.
---
--- Returns:
---  * The ScreenRecorder object
function obj:start()
    if self.menuBarItem then return self end
    self.menuBarItem = hs.menubar.new()
    self.menuBarItem:setMenu(function() return self:_menuItems() end)
    self:_updateTitle()
    return self
end

--- ScreenRecorder:stop()
--- Method
--- Stops any recording or selection in progress and removes the menubar item.
---
--- Returns:
---  * The ScreenRecorder object
function obj:stop()
    if self._recording then self._recording.task:interrupt() end
    if self._selector then self:_cancelSelection() end
    if self.menuBarItem then
        self.menuBarItem:delete()
        self.menuBarItem = nil
    end
    return self
end

--- ScreenRecorder:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for ScreenRecorder.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---   * toggle - Select an area and start recording, or stop the current recording
---
--- Returns:
---  * The ScreenRecorder object
function obj:bindHotkeys(mapping)
    hs.spoons.bindHotkeysToSpec({ toggle = function() self:toggleRecording() end }, mapping)
    return self
end

return obj
