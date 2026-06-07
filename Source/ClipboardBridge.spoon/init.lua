--- === ClipboardBridge ===
---
--- Serves the current clipboard image over a Unix domain socket so that
--- external tools (e.g. AI agents in Docker containers) can read screenshots
--- without any network exposure. The socket is a plain file; it is invisible
--- to the network and cannot be reached from another machine.
---
--- Docker containers access the socket via a bind-mount (see compose.yaml) and use:
---   curl -sf --unix-socket "$CLIPBOARD_BRIDGE_SOCK" http://localhost/

local obj = {}
obj.__index = obj

--- ClipboardBridge.name
--- Constant
--- The name of this Spoon
obj.name = "ClipboardBridge"

--- ClipboardBridge.version
--- Constant
--- The version of this Spoon
obj.version = "2.0"

--- ClipboardBridge.author
--- Constant
--- The author of this Spoon
obj.author = "Facing Quantum <111430155+facing-quantum@users.noreply.github.com>"

--- ClipboardBridge.homepage
--- Constant
--- The homepage for this Spoon
obj.homepage = "https://github.com/Hammerspoon/Spoons"

--- ClipboardBridge.license
--- Constant
--- The license for this Spoon (MIT)
obj.license = "MIT"

--- ClipboardBridge.socketPath
--- Variable
--- Path to the Unix domain socket file.
--- Default: ~/.hammerspoon/clipboard-bridge.sock
--- Volume-mount the parent directory into Docker containers to allow access.
obj.socketPath = os.getenv("HOME") .. "/.hammerspoon/clipboard-bridge.sock"

--- ClipboardBridge.maxAge
--- Variable
--- Seconds after which a clipboard image is considered stale and a 204 is
--- returned instead. Default 60 (1 minute).
obj.maxAge = 60

local _watcher, _server, _imageTimestamp, _pollTimer

-- ── Helpers ────────────────────────────────────────────────────────────

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local HTTP_204 = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
local HTTP_500 = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"

-- ── Request handler ────────────────────────────────────────────────────

local function handleRequest(self)
    -- Only gate on maxAge when the timestamp is known; a nil timestamp means
    -- the watcher fired before the image was fully written — fall through to
    -- readImage() which is the ground truth.
    if _imageTimestamp and (os.time() - _imageTimestamp) > self.maxAge then
        return HTTP_204
    end

    local img = hs.pasteboard.readImage()
    if not img then
        return HTTP_204
    end

    local bare = os.tmpname()
    local tmp  = bare .. ".png"
    os.remove(bare)  -- os.tmpname() creates a placeholder; remove it since we use a different path

    if not img:saveToFile(tmp) then
        os.remove(tmp)
        print("[ClipboardBridge] saveToFile failed for: " .. tmp)
        return HTTP_500
    end

    local f = io.open(tmp, "rb")
    if not f then
        os.remove(tmp)
        return HTTP_500
    end

    local data = f:read("*all")
    f:close()
    os.remove(tmp)

    return "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nConnection: close\r\nContent-Length: " .. #data .. "\r\n\r\n" .. data
end

-- ── Lifecycle ──────────────────────────────────────────────────────────

--- ClipboardBridge:start()
--- Method
--- Starts the clipboard watcher and Unix socket server.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardBridge object
function obj:start()
    if _watcher    then _watcher:stop();        _watcher    = nil end
    if _server     then _server:disconnect();   _server     = nil end
    if _pollTimer  then _pollTimer:stop();      _pollTimer  = nil end
    _imageTimestamp = nil

    _watcher = hs.pasteboard.watcher.new(function()
        if hs.pasteboard.readImage() then
            _imageTimestamp = os.time()
        end
        -- Do not clear on non-image changes: handleRequest checks readImage() directly.
        -- Clearing here causes spurious 204s when clipboard managers briefly reformat
        -- the image (watcher fires with no image before the image format is restored).
    end)
    _watcher:start()
    if hs.pasteboard.readImage() then _imageTimestamp = os.time() end

    os.remove(self.socketPath)  -- remove stale socket file from a previous run
    _server = hs.socket.server(self.socketPath, function()
        if not _server then return end
        _server:write(handleRequest(self))
        _server:read("\r\n\r\n")  -- re-arm before write completes so no gap on quick reconnects
    end)
    if not _server then
        print("[ClipboardBridge] failed to create socket server at: " .. self.socketPath)
        return self
    end
    -- hs.socket has no accept callback, so reads must be armed after each
    -- new connection arrives. Poll every 50ms and arm reads when clients
    -- are present; the data callback re-arms after each handled request.
    _pollTimer = hs.timer.doEvery(0.5, function()
        if _server and _server:connections() > 0 then
            _server:read("\r\n\r\n")
        end
    end)

    os.execute("chmod 600 " .. shellQuote(self.socketPath))

    hs.notify.new({ title = "ClipboardBridge", informativeText = "Listening on " .. self.socketPath }):send()
    return self
end

--- ClipboardBridge:stop()
--- Method
--- Stops the clipboard watcher and Unix socket server. The socket file is
--- removed automatically by hs.socket on disconnect.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardBridge object
function obj:stop()
    if _watcher    then _watcher:stop();        _watcher    = nil end
    if _server     then _server:disconnect();   _server     = nil end
    if _pollTimer  then _pollTimer:stop();      _pollTimer  = nil end
    _imageTimestamp = nil
    return self
end

return obj
