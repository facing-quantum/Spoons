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

return obj
