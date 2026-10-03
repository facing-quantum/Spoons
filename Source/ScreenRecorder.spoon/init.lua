--- === ScreenRecorder ===
---
--- Record a selected area of the screen to .mov, converted to GIF, WebP, AVIF or MP4 when ffmpeg is installed
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

--- ScreenRecorder.outputFormat
--- Variable
--- Default output format: `"gif"`, `"webp"`, `"avif"` or `"mp4"`. Defaults to `"gif"`.
--- A format chosen from the menubar Format submenu is remembered and takes precedence over this value.
obj.outputFormat = "gif"

--- ScreenRecorder.animationFps
--- Variable
--- Frame rate for GIF, WebP and AVIF output. Defaults to `10`. MP4 keeps the recording's native frame rate.
obj.animationFps = 10

--- ScreenRecorder.animationMaxWidth
--- Variable
--- Maximum width in pixels for GIF, WebP and AVIF output. Defaults to `800`. MP4 keeps the recording's native size.
obj.animationMaxWidth = 800

--- ScreenRecorder.logger
--- Variable
--- Logger object used within the Spoon. Messages appear in the Hammerspoon console.
obj.logger = hs.logger.new("ScreenRecorder")

--- ScreenRecorder.menuBarItem
--- Variable
--- The `hs.menubar` item, created by `ScreenRecorder:start()`.
obj.menuBarItem = nil

local SETTINGS_KEY = "ScreenRecorder.maxSeconds"
local FORMAT_SETTINGS_KEY = "ScreenRecorder.outputFormat"
local OUTPUT_FORMATS = { "gif", "webp", "avif", "mp4" }
local FORMAT_LABELS = { gif = "GIF", webp = "WebP", avif = "AVIF", mp4 = "MP4" }
local DEFAULT_MAX_SECONDS = 30
local MIN_SELECTION_SIZE = 10
local BORDER_WIDTH = 3
local FFMPEG_CANDIDATES = { "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }

-- screencapture -v ignores stdin and discards the file on any signal; only the system
-- stop-recording shortcut (Cmd-Ctrl-Esc) stops it and saves.
local function stopCapture()
    hs.eventtap.keyStroke({ "cmd", "ctrl" }, "escape")
end

local function fileExists(path)
    return hs.fs.attributes(path) ~= nil
end

local function anyCaptureFileExists(base)
    if fileExists(base .. ".mov") then return true end
    for _, format in ipairs(OUTPUT_FORMATS) do
        if fileExists(base .. "." .. format) then return true end
    end
    return false
end

function obj._uniqueBaseName(dir, timestamp)
    local base = dir .. "/Capture-" .. timestamp
    local candidate = base
    local suffix = 1
    while anyCaptureFileExists(candidate) do
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

-- Animated formats are downscaled; libaom and libx264 need even dimensions for yuv420p.
function obj._ffmpegArgs(format, movPath, outPath, fps, maxWidth)
    local animatedScale = string.format("fps=%d,scale='trunc(min(%d,iw)/2)*2':-2:flags=lanczos", fps, maxWidth)
    local encoderArgs = {
        gif = { "-vf", animatedScale .. ",split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" },
        webp = { "-vf", animatedScale, "-c:v", "libwebp_anim", "-quality", "80", "-loop", "0" },
        avif = { "-vf", animatedScale, "-c:v", "libaom-av1", "-crf", "30", "-b:v", "0", "-cpu-used", "6", "-pix_fmt", "yuv420p" },
        mp4 = { "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-crf", "23", "-preset", "medium", "-pix_fmt", "yuv420p", "-movflags", "+faststart" },
    }
    local args = { "-y", "-i", movPath, "-an" }
    for _, arg in ipairs(encoderArgs[format]) do table.insert(args, arg) end
    table.insert(args, outPath)
    return args
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
--- Returns the configured max recording length.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The max length in seconds; `0` means no limit
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
---
--- Returns:
---  * None
function obj:setMaxSeconds(seconds)
    hs.settings.set(SETTINGS_KEY, seconds)
end

--- ScreenRecorder:format()
--- Method
--- Returns the output format recordings are converted to.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The format chosen in the menubar if one was saved, otherwise `ScreenRecorder.outputFormat`
function obj:format()
    local saved = hs.settings.get(FORMAT_SETTINGS_KEY)
    if FORMAT_LABELS[saved] then return saved end
    if FORMAT_LABELS[self.outputFormat] then return self.outputFormat end
    obj.logger.w("unknown outputFormat " .. tostring(self.outputFormat) .. ", using gif")
    return "gif"
end

--- ScreenRecorder:setFormat(format)
--- Method
--- Sets and persists the output format, taking precedence over `ScreenRecorder.outputFormat`.
---
--- Parameters:
---  * format - `"gif"`, `"webp"`, `"avif"` or `"mp4"`
---
--- Returns:
---  * None
function obj:setFormat(format)
    hs.settings.set(FORMAT_SETTINGS_KEY, format)
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
    local formatMenu = {}
    for _, format in ipairs(OUTPUT_FORMATS) do
        table.insert(formatMenu, {
            title = FORMAT_LABELS[format],
            checked = (format == self:format()),
            fn = function() self:setFormat(format) end,
        })
    end
    return {
        { title = self._recording and "Stop Recording" or "Start Recording", fn = function() self:toggleRecording() end },
        { title = "Max Length", menu = lengthMenu },
        { title = "Format", menu = formatMenu },
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
--- Parameters:
---  * None
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
--- Parameters:
---  * None
---
--- Returns:
---  * The ScreenRecorder object
function obj:stop()
    if self._recording then stopCapture() end
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

function obj:_selectArea(onSelected)
    local screenFrame = hs.mouse.getCurrentScreen():fullFrame()
    local canvas = hs.canvas.new(screenFrame)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas[1] = { type = "rectangle", action = "fill", fillColor = { black = 1, alpha = 0.3 } }
    canvas[2] = {
        type = "rectangle", action = "strokeAndFill",
        strokeColor = { red = 1 }, strokeWidth = 1, fillColor = { white = 1, alpha = 0.15 },
        frame = { x = 0, y = 0, w = 0, h = 0 },
    }

    local startPoint = nil
    local function rectTo(point)
        return {
            x = math.min(startPoint.x, point.x), y = math.min(startPoint.y, point.y),
            w = math.abs(point.x - startPoint.x), h = math.abs(point.y - startPoint.y),
        }
    end

    local types = hs.eventtap.event.types
    local tap = hs.eventtap.new({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp, types.keyDown }, function(event)
        local eventType = event:getType()
        if eventType == types.keyDown then
            if event:getKeyCode() ~= hs.keycodes.map.escape then return false end
            self:_cancelSelection()
            return true
        end
        local location = event:location()
        local point = {
            x = math.max(screenFrame.x, math.min(location.x, screenFrame.x + screenFrame.w)),
            y = math.max(screenFrame.y, math.min(location.y, screenFrame.y + screenFrame.h)),
        }
        if eventType == types.leftMouseDown then
            startPoint = point
        elseif startPoint and eventType == types.leftMouseDragged then
            local rect = rectTo(point)
            canvas[2].frame = { x = rect.x - screenFrame.x, y = rect.y - screenFrame.y, w = rect.w, h = rect.h }
        elseif startPoint and eventType == types.leftMouseUp then
            local rect = rectTo(point)
            self:_cancelSelection()
            if rect.w >= MIN_SELECTION_SIZE and rect.h >= MIN_SELECTION_SIZE then onSelected(rect) end
        end
        return true
    end)

    self._selector = { canvas = canvas, tap = tap }
    canvas:show()
    tap:start()
end

function obj:_cancelSelection()
    if not self._selector then return end
    self._selector.tap:stop()
    self._selector.canvas:delete()
    self._selector = nil
end

--- ScreenRecorder:toggleRecording()
--- Method
--- Stops the current recording; otherwise cancels an in-progress selection; otherwise lets the user drag an area and starts recording it.
---
--- Parameters:
---  * None
---
--- Returns:
---  * None
function obj:toggleRecording()
    if self._recording then
        stopCapture()
    elseif self._selector then
        self:_cancelSelection()
    else
        self:_selectArea(function(rect) self:_startRecording(rect) end)
    end
end

function obj:_startRecording(selectedRect)
    local rect = {
        x = math.floor(selectedRect.x), y = math.floor(selectedRect.y),
        w = math.floor(selectedRect.w), h = math.floor(selectedRect.h),
    }
    local base = obj._uniqueBaseName(self.outputDir, os.date("%Y-%m-%d-%H%M%S"))
    local movPath = base .. ".mov"

    local border = hs.canvas.new({
        x = rect.x - BORDER_WIDTH, y = rect.y - BORDER_WIDTH,
        w = rect.w + 2 * BORDER_WIDTH, h = rect.h + 2 * BORDER_WIDTH,
    })
    border:level(hs.canvas.windowLevels.overlay)
    border[1] = {
        type = "rectangle", action = "stroke", strokeColor = { red = 1 }, strokeWidth = BORDER_WIDTH,
        frame = { x = BORDER_WIDTH / 2, y = BORDER_WIDTH / 2, w = rect.w + BORDER_WIDTH, h = rect.h + BORDER_WIDTH },
    }

    -- ponytail: a Hammerspoon reload mid-recording orphans screencapture until -V ends it (never, with No limit); persist the pid and kill it on start() if that bites.
    local args = obj._screencaptureArgs(rect, self:maxSeconds(), movPath)
    local command = "/usr/sbin/screencapture " .. table.concat(args, " ")
    obj.logger.i("starting: " .. command)
    local task = hs.task.new("/usr/sbin/screencapture", function(exitCode, stdOut, stdErr)
        self:_recordingFinished(base, exitCode, stdOut, stdErr)
    end, args)

    self._recording = {
        task = task,
        border = border,
        timer = hs.timer.doEvery(1, function() self:_updateTitle() end),
        startedAt = os.time(),
        command = command,
    }
    border:show()
    if not task:start() then
        self:_recordingFinished(base, -1, "", "hs.task could not launch /usr/sbin/screencapture")
        return
    end
    self:_updateTitle()
end

function obj:_recordingFinished(base, exitCode, stdOut, stdErr)
    local recording = self._recording
    self._recording = nil
    recording.timer:stop()
    recording.border:delete()
    self:_updateTitle()

    local movPath = base .. ".mov"
    local size = hs.fs.attributes(movPath, "size")
    local summary = string.format("screencapture exit %s, file size %s, stderr: %s, stdout: %s, command: %s",
        tostring(exitCode), tostring(size), stdErr or "", stdOut or "", recording.command)
    if not size or size == 0 then
        obj.logger.e(summary)
        os.remove(movPath)
        hs.alert.show("ScreenRecorder: recording failed (exit " .. tostring(exitCode) .. "), see Hammerspoon console. Check System Settings › Privacy & Security › Screen Recording.")
        return
    end
    obj.logger.i(summary)
    self:_convert(base)
end

function obj:_convert(base)
    local format = self:format()
    local movPath, outPath = base .. ".mov", base .. "." .. format
    local ffmpeg = obj._findFfmpeg()
    if not ffmpeg then
        if not self._warnedNoFfmpeg then
            self._warnedNoFfmpeg = true
            hs.alert.show("ScreenRecorder: ffmpeg not found, saved .mov only (brew install ffmpeg to convert)")
        end
        self:_deliver(movPath)
        return
    end
    local args = obj._ffmpegArgs(format, movPath, outPath, self.animationFps, self.animationMaxWidth)
    self._converting = self._converting or {}
    local task
    task = hs.task.new(ffmpeg, function(exitCode, _, stderr)
        self._converting[task] = nil
        if exitCode == 0 then
            self:_deliver(outPath)
        else
            os.remove(outPath)
            obj.logger.e(string.format("ffmpeg exit %s, stderr: %s, command: %s %s", tostring(exitCode), stderr or "", ffmpeg, table.concat(args, " ")))
            hs.alert.show("ScreenRecorder: " .. FORMAT_LABELS[format] .. " export failed, see Hammerspoon console: " .. (stderr or ""):sub(-200))
            self:_deliver(movPath)
        end
    end, args)
    obj.logger.i("starting: " .. ffmpeg .. " " .. table.concat(args, " "))
    self._converting[task] = true
    task:start()
end

function obj:_deliver(path)
    hs.pasteboard.writeObjects({ url = "file://" .. (path:gsub(" ", "%%20")) })
    hs.task.new("/usr/bin/open", nil, { "-R", path }):start()
end

return obj
