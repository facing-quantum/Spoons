--- === ClipboardBridge ===
---
--- Serves the current clipboard image over a Unix domain socket so that
--- external tools (e.g. AI agents in Docker containers) can read screenshots
--- without any network exposure. The socket is a plain file; it is invisible
--- to the network and cannot be reached from another machine.
---
--- Docker containers access the socket via a bind-mount (see compose.yaml) and use:
---   curl -sf \
---     --unix-socket "$CLIPBOARD_BRIDGE_SOCK" \
---     -H "Authorization: Bearer $CLIPBOARD_BRIDGE_TOKEN" \
---     http://localhost/
---
--- Security default:
---   - Token auth is enabled when CLIPBOARD_BRIDGE_TOKEN is set.
---   - Set authToken to empty/nil to allow unauthenticated requests.
---   - Unauthorized requests can trigger a local notification.
---   - Set unauthorizedNotificationRateLimit to 0/nil to disable notifications.

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

--- ClipboardBridge.authToken
--- Variable
--- Bearer token required by clients when set.
--- Default: CLIPBOARD_BRIDGE_TOKEN environment variable.
--- Set to empty/nil to disable auth checks.
obj.authToken = os.getenv("CLIPBOARD_BRIDGE_TOKEN") or ""

--- ClipboardBridge.maxAge
--- Variable
--- Seconds after which a clipboard image is considered stale and a 204 is
--- returned instead. Default 60 (1 minute).
obj.maxAge = 60

--- ClipboardBridge.unauthorizedNotificationRateLimit
--- Variable
--- Minimum number of seconds between unauthorized access notifications.
--- Default: 60. Set to 0/nil to disable unauthorized notifications.
obj.unauthorizedNotificationRateLimit = 60

local _watcher, _server, _imageTimestamp, _pollTimer, _lastUnauthorizedNotificationAt

-- ── Helpers ────────────────────────────────────────────────────────────

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local HTTP_204 = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
local HTTP_401 = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer realm=\"ClipboardBridge\"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
local HTTP_500 = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
local READ_DELIMITER = "\r\n\r\n"
local POLL_INTERVAL_SECONDS = 0.5

-- ── Request handler ────────────────────────────────────────────────────

local function resetRuntime()
    if _watcher    then _watcher:stop();      _watcher    = nil end
    if _server     then _server:disconnect(); _server     = nil end
    if _pollTimer  then _pollTimer:stop();    _pollTimer  = nil end
    _imageTimestamp = nil
    _lastUnauthorizedNotificationAt = nil
end

local function notifyUnauthorizedAttempt(self)
    local now = os.time()
    local rateLimit = tonumber(self.unauthorizedNotificationRateLimit)
    if not rateLimit or rateLimit <= 0 then
        return
    end

    if _lastUnauthorizedNotificationAt and (now - _lastUnauthorizedNotificationAt) < rateLimit then
        return
    end

    _lastUnauthorizedNotificationAt = now
    hs.notify.new({
        title = "ClipboardBridge",
        informativeText = "Unauthorized clipboard access attempt blocked",
    }):send()
end

local function parseHeaders(request)
    local headers = {}
    for line in request:gmatch("[^\r\n]+") do
        local name, value = line:match("^([%w-]+):%s*(.+)$")
        if name then
            headers[name:lower()] = value:match("^%s*(.-)%s*$")
        end
    end
    return headers
end

local function isAuthorized(self, headers)
    if not self.authToken or self.authToken == "" then
        return false
    end

    local authorization = headers["authorization"]
    if authorization then
        local token = authorization:match("^Bearer%s+(.+)$")
        if token and token:match("^%s*(.-)%s*$") == self.authToken then
            return true
        end
    end

    local headerToken = headers["x-clipboard-bridge-token"]
    return headerToken == self.authToken
end

local function requestFromArgs(a, b)
    if type(a) == "string" then
        return a
    end
    if type(b) == "string" then
        return b
    end
    return nil
end

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

local function handleConnection(self, request)
    if not self.authToken or self.authToken == "" then
        return handleRequest(self)
    end

    if not request or request == "" then
        notifyUnauthorizedAttempt(self)
        return HTTP_401
    end

    local headers = parseHeaders(request)
    if not isAuthorized(self, headers) then
        notifyUnauthorizedAttempt(self)
        return HTTP_401
    end

    return handleRequest(self)
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
    resetRuntime()

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
    _server = hs.socket.server(self.socketPath, function(a, b)
        if not _server then return end
        local request = requestFromArgs(a, b)
        _server:write(handleConnection(self, request))
        _server:read(READ_DELIMITER)  -- re-arm before write completes so no gap on quick reconnects
    end)
    if not _server then
        print("[ClipboardBridge] failed to create socket server at: " .. self.socketPath)
        return self
    end
    -- hs.socket has no accept callback, so reads must be armed after each
    -- new connection arrives. Poll every 500ms and arm reads when clients
    -- are present; the data callback re-arms after each handled request.
    _pollTimer = hs.timer.doEvery(POLL_INTERVAL_SECONDS, function()
        if _server and _server:connections() > 0 then
            _server:read(READ_DELIMITER)
        end
    end)

    os.execute("chmod 600 " .. shellQuote(self.socketPath))

    hs.notify.new({ title = "ClipboardBridge", informativeText = "Listening on " .. self.socketPath }):send()
    return self
end

--- ClipboardBridge:stop()
--- Method
--- Stops the clipboard watcher and Unix socket server.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardBridge object
---
--- Notes:
---  * The socket file is removed automatically by hs.socket on disconnect.
function obj:stop()
    resetRuntime()
    return self
end

return obj
