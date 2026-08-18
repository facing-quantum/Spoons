--- === ClaudeUsage ===
---
--- Displays Claude AI plan usage limits in the macOS menu bar as two stacked
--- segmented progress bars (current session and weekly). Clicking the icon
--- expands a dropdown mirroring the platform.claude.com usage page with
--- reset times in the local timezone.
---
--- The dropdown also reports Claude service health from the public Statuspage
--- API at status.claude.com: per-component status, a rolling incident summary,
--- and a submenu of recent incidents linking to their status page entries.
---
--- Credentials are read from the macOS Keychain entry "Claude Code-credentials"
--- (set by Claude Code) with a fallback to ~/.claude/.credentials.json. The
--- status endpoints are public and need no authentication.

local obj = {}
obj.__index = obj

--- ClaudeUsage.name
--- Constant
--- The name of this Spoon
obj.name = "ClaudeUsage"

--- ClaudeUsage.version
--- Constant
--- The version of this Spoon
obj.version = "1.0"

--- ClaudeUsage.author
--- Constant
--- The author of this Spoon
obj.author = "Facing Quantum <111430155+facing-quantum@users.noreply.github.com>"

--- ClaudeUsage.license
--- Constant
--- The license for this Spoon (MIT)
obj.license = "MIT"

--- ClaudeUsage.homepage
--- Constant
--- The homepage for this Spoon
obj.homepage = "https://github.com/Hammerspoon/Spoons"

--- ClaudeUsage.pollInterval
--- Variable
--- Seconds between usage API fetches. Default 120.
obj.pollInterval = 120

--- ClaudeUsage.statusPollInterval
--- Variable
--- Minimum seconds between status.claude.com component fetches. Default 300.
--- Checked on each poll tick, so the effective interval is rounded up to the
--- next multiple of ClaudeUsage.pollInterval.
obj.statusPollInterval = 300

--- ClaudeUsage.incidentsPollInterval
--- Variable
--- Minimum seconds between status.claude.com incident history fetches.
--- Default 900. This response is much larger than the component summary and
--- changes rarely, so it is polled far less often.
obj.incidentsPollInterval = 900

--- ClaudeUsage.autoRefreshToken
--- Variable
--- When true, the spoon will attempt to refresh an expired OAuth token itself
--- and write the result back to ~/.claude/.credentials.json. Disabled by default:
--- Claude Code owns the token lifecycle and will refresh it on its next run.
--- Enable only if the spoon is running without Claude Code active.
obj.autoRefreshToken = false

local menubar, timer
local lastData, lastFetchTime, fetchError, planName
local statusData, statusFetchTime, statusError, statusAttemptTime
local incidentsData, incidentsError, incidentsAttemptTime
local tsCache     = {}
local isFetching       = false
local rateLimitedUntil = 0

-- Assigned in the Fetch section; declared here so buildMenu can close over them.
local fetchStatus, fetchIncidents

local CREDS_PATH    = os.getenv("HOME") .. "/.claude/.credentials.json"
local USAGE_URL     = "https://api.anthropic.com/api/oauth/usage"
local TOKEN_URL     = "https://platform.claude.com/v1/oauth/token"
local STATUS_URL    = "https://status.claude.com/api/v2/summary.json"
local INCIDENTS_URL = "https://status.claude.com/api/v2/incidents.json"

-- status.claude.com is Atlassian Statuspage, not Anthropic infrastructure
-- (CNAME → tymt9n04zgry.stspg-customer.com). These endpoints are public and are
-- sent no credentials.

-- ── Claude binary discovery ────────────────────────────────────────────
-- All three values are resolved once on first use and cached; they update
-- automatically on next Hammerspoon reload after a Claude Code upgrade.

local _cachedBinPath   = nil
local _cachedClientId  = nil
local _cachedUserAgent = nil
local _cachedOauthBeta = nil

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function claudeBinPath()
  if _cachedBinPath then return _cachedBinPath end
  local link   = os.getenv("HOME") .. "/.local/bin/claude"
  local target = hs.execute("readlink " .. shellQuote(link) .. " 2>/dev/null"):gsub("%s+$", "")
  if target == ""            then _cachedBinPath = link; return link end
  if target:sub(1,1) ~= "/" then target = (link:match("(.*/)") or "") .. target end
  _cachedBinPath = target
  return target
end

local function getClientId()
  if _cachedClientId then return _cachedClientId end
  local id = hs.execute(
    "strings " .. shellQuote(claudeBinPath()) ..
    " 2>/dev/null | grep -oE 'CLIENT_ID:\"[0-9a-f-]+\"' | grep -oE '[0-9a-f-]{36}' | head -1"
    ):gsub("%s+$", "")
  if not id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
    id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  -- extracted from v2.1.158
    print("[ClaudeUsage] WARNING: could not discover client_id from binary, using fallback")
  end
  _cachedClientId = id
  return id
end

local function getUserAgent()
  if _cachedUserAgent then return _cachedUserAgent end
  local ver = hs.execute(
    shellQuote(claudeBinPath()) .. " --version 2>/dev/null"):gsub("%s+$", "")
  local v  = ver:match("^([0-9]+%.[0-9]+%.[0-9]+)")
  _cachedUserAgent = v and ("claude-code/" .. v) or "claude-code/1.0.0"
  return _cachedUserAgent
end

local function getOauthBeta()
  if _cachedOauthBeta then return _cachedOauthBeta end
  local val = hs.execute(
    "strings " .. shellQuote(claudeBinPath()) ..
    " 2>/dev/null | grep -oE 'oauth-[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1"
    ):gsub("%s+$", "")
  if val == "" then
    val = "oauth-2025-04-20"  -- extracted from v2.1.158
    print("[ClaudeUsage] WARNING: could not discover anthropic-beta from binary, using fallback")
  end
  _cachedOauthBeta = val
  return val
end

-- ── Color ──────────────────────────────────────────────────────────────

local SESSION_CLR = {red=0.851, green=0.467, blue=0.337, alpha=1}  -- warm coral  #D97756
local WEEKLY_CLR  = {red=0.769, green=0.635, blue=0.349, alpha=1}  -- golden tan  #C4A259
local ROUTINE_CLR = {red=0.529, green=0.620, blue=0.788, alpha=1}  -- slate blue  #879EC9
local SAGE_CLR    = {red=0.400, green=0.620, blue=0.480, alpha=1}  -- sage green  #66A07A
local WARN_RED    = {red=0.85,  green=0.22,  blue=0.18,  alpha=1}  -- high-usage red
local AMBER       = {red=0.95,  green=0.65,  blue=0.10,  alpha=1}


local function lerpColor(a, b, t)
  return {red   = a.red   + (b.red   - a.red)   * t,
          green = a.green + (b.green - a.green) * t,
          blue  = a.blue  + (b.blue  - a.blue)  * t,
          alpha = a.alpha + (b.alpha - a.alpha) * t}
end

local function barColor(base, pct)
  return lerpColor(base, WARN_RED, math.max(0, math.min(1, (pct - 70) / 25)))
end

-- ── Time ───────────────────────────────────────────────────────────────

-- Days between 1970-01-01 and the given proleptic Gregorian date. Handles
-- leap years, century non-leaps and 400-year leaps exactly.
local function daysFromCivil(year, month, day)
  local y = (month <= 2) and (year - 1) or year
  local era = math.floor(y / 400)
  local yearOfEra = y - era * 400
  local shiftedMonth = month + ((month > 2) and -3 or 9)
  local dayOfYear = math.floor((153 * shiftedMonth + 2) / 5) + day - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4)
                   - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

-- Both APIs emit UTC, so there is no DST or offset handling to do and any
-- trailing offset is ignored. Parsing in Lua avoids a shell fork per timestamp,
-- which matters because incident history carries dozens of them.
local function utcIsoToUnix(s)
  if not s then return nil end
  if tsCache[s] then return tsCache[s] end
  local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    print("[ClaudeUsage] utcIsoToUnix: failed to parse timestamp: " .. tostring(s))
    return nil
  end
  local ts = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
             + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  tsCache[s] = ts
  return ts
end

local function formatReset(s)
  local ts = utcIsoToUnix(s)
  if not ts then return "unknown" end
  return os.date("%a %b %d at %I:%M %p", ts)
end

-- e.g. 90061 → "1w 1d", 3720 → "1h 2m", 45 → "45s"
local function humanDuration(secs)
  secs = math.floor(math.max(0, secs))
  if secs < 60 then return secs .. "s" end
  local weeks = math.floor(secs / 604800); secs = secs % 604800
  local days  = math.floor(secs / 86400);  secs = secs % 86400
  local hours = math.floor(secs / 3600);   secs = secs % 3600
  local mins  = math.floor(secs / 60)
  if weeks > 0 then return weeks.."w" .. (days  > 0 and " "..days.."d"  or "") end
  if days  > 0 then return days.."d"  .. (hours > 0 and " "..hours.."h" or "") end
  if hours > 0 then return hours.."h" .. (mins  > 0 and " "..mins.."m"  or "") end
  return mins .. "m"
end

local function formatCountdown(s)
  local ts = utcIsoToUnix(s)
  if not ts then return "" end
  local diff = ts - os.time()
  if diff <= 0 then return "resetting…" end
  return humanDuration(diff)
end

local FIVE_HOUR_SECS = 18000   -- 5 * 3600
local SEVEN_DAY_SECS = 604800  -- 7 * 86400

local function timeRemainingPct(resets_at_iso, window_secs)
  local rt = utcIsoToUnix(resets_at_iso)
  if not rt then return 0 end
  local linear = math.max(0, math.min(1, (rt - os.time()) / window_secs))
  return math.sqrt(linear) * 100  -- sqrt scale: keeps bar visible near zero
end

-- ── Claude status ──────────────────────────────────────────────────────
-- Component health uses semantic shapes rather than a severity ramp: the set
-- includes a healthy state, and a ramp would either shout when all is well or
-- whisper during an outage. Incident impact carries no glyph at all and tints
-- the incident title instead.

local COMPONENT_STATE = {
  operational          = {glyph="✓", label="operational",    color=SAGE_CLR},
  degraded_performance = {glyph="▲", label="degraded",       color=AMBER},
  partial_outage       = {glyph="◐", label="partial outage", color=AMBER},
  major_outage         = {glyph="✕", label="major outage",   color=WARN_RED},
  under_maintenance    = {glyph="◇", label="maintenance",    color=ROUTINE_CLR},
}

local INDICATOR_COLOR = {
  none        = SAGE_CLR,
  minor       = AMBER,
  major       = WARN_RED,
  critical    = WARN_RED,
  maintenance = ROUTINE_CLR,
}

local IMPACT_COLOR = {
  minor       = AMBER,
  major       = WARN_RED,
  critical    = WARN_RED,
  maintenance = ROUTINE_CLR,
}

-- Statuspage sets impact independently of the incident title, so an entry whose
-- prose mentions errors is still dim when it is classified "none". An impact
-- this spoon does not recognise gets amber rather than silently borrowing the
-- dim of a genuine "none", and is reported once so it can be mapped later.
local loggedImpacts = {}
local function impactColor(impact, dim)
  if impact == "none" then return dim end
  local color = IMPACT_COLOR[impact]
  if color then return color end
  local key = tostring(impact)
  if not loggedImpacts[key] then
    loggedImpacts[key] = true
    print("[ClaudeUsage] unknown incident impact: " .. key)
  end
  return AMBER
end

-- Unknown statuses are drawn in amber rather than hidden: a state this spoon
-- has not seen before is more likely to be bad news than good.
local function componentState(status)
  local state = COMPONENT_STATE[status]
  if state then return state end
  return {glyph="·", color=AMBER,
          label=status and status:gsub("_", " ") or "unknown"}
end

-- "Claude API (api.anthropic.com)" → "Claude API". Stripping the parenthetical
-- rather than mapping known names keeps new components readable.
local function shortComponentName(name)
  return (tostring(name):gsub("%s*%b()", ""))
end

local function componentSince(component)
  local ts = utcIsoToUnix(component.updated_at)
  if not ts then return nil end
  return humanDuration(os.time() - ts)
end

local function incidentStart(incident)
  return utcIsoToUnix(incident.started_at or incident.created_at)
end

local function incidentDuration(incident)
  local startTs = incidentStart(incident)
  if not startTs then return nil end
  local endTs = incident.resolved_at and utcIsoToUnix(incident.resolved_at) or os.time()
  if not endTs then return nil end
  return math.max(0, endTs - startTs)
end

-- Statuspage exposes no uptime or metrics endpoint, so recent reliability is
-- derived from incident durations instead. Incident time is not downtime, and
-- the API only returns roughly the last three weeks.
local function incidentStats(incidents)
  local now = os.time()
  local stats = {weekCount=0, weekSecs=0, critical=0, major=0, windowDays=0}
  local oldest
  for _, incident in ipairs(incidents) do
    local startTs = incidentStart(incident)
    if startTs then
      if not oldest or startTs < oldest then oldest = startTs end
      if now - startTs <= SEVEN_DAY_SECS then
        stats.weekCount = stats.weekCount + 1
        stats.weekSecs  = stats.weekSecs + (incidentDuration(incident) or 0)
      end
      if incident.impact == "critical" then stats.critical = stats.critical + 1 end
      if incident.impact == "major"    then stats.major    = stats.major    + 1 end
    end
  end
  if oldest then stats.windowDays = math.floor((now - oldest) / 86400) end
  return stats
end

-- ── Auth ───────────────────────────────────────────────────────────────

-- Returns (accessToken, planDisplay, error, refreshToken).
-- refreshToken is returned even on "expired" so callers can attempt a refresh.
local function parseCredentials(raw)
  if not raw or raw:match("^%s*$") then return nil, nil, "empty", nil end
  local token   = raw:match('"accessToken"%s*:%s*"([^"]+)"')
  local plan    = raw:match('"subscriptionType"%s*:%s*"([^"]+)"')
  local expMs   = tonumber(raw:match('"expiresAt"%s*:%s*(%d+)'))
  local refresh = raw:match('"refreshToken"%s*:%s*"([^"]+)"')
  if not token then return nil, nil, "no_token", nil end
  if expMs then
    local expSec = math.floor(expMs / 1000)
    if expSec <= os.time() then
      print(string.format("[ClaudeUsage] token EXPIRED at %s local",
        os.date("%Y-%m-%d %H:%M:%S", expSec)))
      return nil, nil, "expired", refresh
    end
  end
  local pd = plan and (plan:sub(1,1):upper() .. plan:sub(2)) or nil
  return token, pd, nil, refresh
end

local function getClaudeKeychain()
  local raw = hs.execute(
    'security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null')
  return parseCredentials(raw and raw:gsub("%s+$", ""))
end

local function loadCredentials()
  local f = io.open(CREDS_PATH, "r")
  if not f then return nil, nil, "no_file" end
  local raw = f:read("*a"); f:close()
  return parseCredentials(raw)
end

-- Returns (accessToken, planDisplay, error, refreshToken).
local function resolveToken()
  local token, pd, err, rt = getClaudeKeychain()
  if token then return token, pd, nil, rt end
  local fToken, fPd, fErr, fRt = loadCredentials()
  if fToken then return fToken, fPd, nil, fRt end
  -- Both failed. Surface the most actionable error; prefer keychain "expired"
  -- over file "no_file" since it tells the user what actually happened.
  if err == "expired" then return nil, nil, err, rt end
  return nil, nil, fErr, fRt
end

-- ── Menu bar icon ──────────────────────────────────────────────────────

local function appendGradientBar(c, baseClr, pct, x0, y0, totalW, h)
  local SEGS   = 8
  local GAP    = 2.5
  local segW   = (totalW - GAP * (SEGS - 1)) / SEGS
  local filled = math.floor(pct / 100 * SEGS)
  for s = 1, SEGS do
    local sx = x0 + (s - 1) * (segW + GAP)
    c:appendElements({type="rectangle", action="fill",
      fillColor={white=0.3, alpha=0.25},
      frame={x=sx, y=y0, w=segW, h=h},
      roundedRectRadii={xRadius=1.5, yRadius=1.5}})
    if s <= filled then
      c:appendElements({type="rectangle", action="fill",
        fillColor=barColor(baseClr, (s / SEGS) * 100),
        frame={x=sx, y=y0, w=segW, h=h},
        roundedRectRadii={xRadius=1.5, yRadius=1.5}})
    end
  end
end

local function appendThinBar(c, clr, pct, x0, y0, totalW, h)
  c:appendElements({type="rectangle", action="fill",
    fillColor={white=0.3, alpha=0.2},
    frame={x=x0, y=y0, w=totalW, h=h},
    roundedRectRadii={xRadius=1, yRadius=1}})
  local filledW = totalW * math.max(0, math.min(1, pct / 100))
  if filledW > 0 then
    c:appendElements({type="rectangle", action="fill",
      fillColor=clr,
      frame={x=x0, y=y0, w=filledW, h=h},
      roundedRectRadii={xRadius=1, yRadius=1}})
  end
end

-- dotColor nil leaves the indicator slot empty. The slot is always reserved so
-- the icon keeps a constant width instead of shifting when an outage starts.
local function buildIcon(sPct, wPct, sTimePct, wTimePct, dotColor)
  sPct = math.max(0, math.min(100, sPct or 0))
  wPct = math.max(0, math.min(100, wPct or 0))
  local W, H, BH     = 102, 26, 8
  local LABEL_W       = 34
  local BAR_X, BAR_W  = 36, 58
  local sc = barColor(SESSION_CLR, sPct)
  local wc = barColor(WEEKLY_CLR,  wPct)
  local c  = hs.canvas.new({x=0, y=0, w=W, h=H})
  c:appendElements({type="text", text=string.format("%d%%", math.floor(sPct)),
    textColor=sc, textSize=11, textAlignment="right",
    frame={x=0, y=0, w=LABEL_W, h=11}})
  appendGradientBar(c, SESSION_CLR, sPct, BAR_X, 2,  BAR_W, BH)
  appendThinBar    (c, SAGE_CLR, sTimePct, BAR_X, 11, BAR_W, 2)
  c:appendElements({type="text", text=string.format("%d%%", math.floor(wPct)),
    textColor=wc, textSize=11, textAlignment="right",
    frame={x=0, y=13, w=LABEL_W, h=11}})
  appendGradientBar(c, WEEKLY_CLR,  wPct, BAR_X, 15, BAR_W, BH)
  appendThinBar    (c, SAGE_CLR, wTimePct, BAR_X, 24, BAR_W, 2)
  if dotColor then
    c:appendElements({type="circle", action="fill", fillColor=dotColor,
      center={x=97, y=13}, radius=3})
  end
  local img = c:imageFromCanvas()
  img:template(false)
  c:delete()
  return img
end

-- The icon indicator tracks Claude Code alone, so an outage confined to Cowork
-- or Government stays quiet. At 6px a shape is illegible, and the indicator only
-- has to answer "is something wrong", so color alone carries it here.
local function claudeCodeDotColor()
  if not statusData or type(statusData.components) ~= "table" then return nil end
  for _, component in ipairs(statusData.components) do
    if component.name == "Claude Code" then
      if component.status == "operational" then return nil end
      return componentState(component.status).color
    end
  end
  return nil
end

local function refreshIcon()
  if not menubar or not lastData then return end
  local sPct     = (lastData.five_hour and lastData.five_hour.utilization) or 0
  local wPct     = (lastData.seven_day and lastData.seven_day.utilization) or 0
  local sTimePct = timeRemainingPct(
    lastData.five_hour and lastData.five_hour.resets_at, FIVE_HOUR_SECS)
  local wTimePct = timeRemainingPct(
    lastData.seven_day and lastData.seven_day.resets_at, SEVEN_DAY_SECS)
  menubar:setIcon(buildIcon(sPct, wPct, sTimePct, wTimePct, claudeCodeDotColor()), false)
  menubar:setTitle("")
end

-- ── Dropdown menu ──────────────────────────────────────────────────────

local function styledBlockBar(pct, baseColor, width)
  width = width or 14
  local emptyColor = {white=0.3, alpha=0.5}
  local n = math.max(0, math.min(width, math.floor(pct / 100 * width)))
  local result = hs.styledtext.new("")
  for i = 1, n do
    result = result .. hs.styledtext.new("█", {color=barColor(baseColor, (i / width) * 100)})
  end
  for _ = n + 1, width do
    result = result .. hs.styledtext.new("█", {color=emptyColor})
  end
  return result
end

local function styledBlockBarFlat(pct, clr, width)
  width = width or 14
  local emptyColor = {white=0.3, alpha=0.5}
  local n = math.max(0, math.min(width, math.floor(pct / 100 * width)))
  local result = hs.styledtext.new("")
  for i = 1, n do
    result = result .. hs.styledtext.new("█", {color=clr})
  end
  for _ = n + 1, width do
    result = result .. hs.styledtext.new("█", {color=emptyColor})
  end
  return result
end

local function labelColor()
  return (hs.host.interfaceStyle() == "Dark")
    and {white=0.85, alpha=0.9} or {white=0.1, alpha=0.9}
end

-- Points available to an incident title before it would reach the duration
-- column, and the font both the measuring and the drawing must agree on.
local INCIDENT_TITLE_WIDTH = 320
local INCIDENT_FONT_NAME   = ".AppleSystemUIFont"
local INCIDENT_FONT_SIZE   = 13

local titleFitCache = {}

-- Menu text is proportional, so a fixed character cap both clips titles that
-- would have fit and lets wide ones reach the duration column. Measure the
-- rendered width instead. Cached by title and font because buildMenu blocks the
-- UI while it runs and the incident list changes far less often than it opens.
local function fitIncidentTitle(text, font)
  local key = font.name .. "|" .. text
  if titleFitCache[key] then return titleFitCache[key] end

  local function widthOf(s)
    local size = hs.drawing.getTextDrawingSize(hs.styledtext.new(s, {font=font}))
    return size and (size.w or size.width or 0) or 0
  end

  -- Never leave a trailing byte from a partially sliced multi-byte character.
  local function trimToCharBoundary(s)
    while #s > 0 do
      local b = s:byte(#s)
      if b >= 0x80 and b < 0xC0 then s = s:sub(1, #s - 1) else break end
    end
    local last = s:byte(#s)
    if last and last >= 0xC0 then s = s:sub(1, #s - 1) end
    return s
  end

  local fitted = text
  if widthOf(text) > INCIDENT_TITLE_WIDTH then
    local full  = widthOf(text)
    local guess = full > 0 and math.floor(#text * INCIDENT_TITLE_WIDTH / full) or #text
    fitted = trimToCharBoundary(text:sub(1, math.max(1, guess)))
    -- The proportional guess lands either side of the budget, so walk to the
    -- boundary in whichever direction is needed.
    while #fitted < #text
      and widthOf(trimToCharBoundary(text:sub(1, #fitted + 1)) .. "…") <= INCIDENT_TITLE_WIDTH do
      fitted = trimToCharBoundary(text:sub(1, #fitted + 1))
    end
    while #fitted > 1 and widthOf(fitted .. "…") > INCIDENT_TITLE_WIDTH do
      fitted = trimToCharBoundary(fitted:sub(1, #fitted - 1))
    end
    fitted = fitted:gsub("%s+$", "") .. "…"
  end

  titleFitCache[key] = fitted
  return fitted
end

-- major and critical share a red, so critical is set bold to keep the two
-- distinguishable now that no glyph separates them.
local function buildIncidentSubmenu(dim, bold)
  -- The key is tabStopType, not alignment, and the style must be carried by
  -- every run: AppKit reads it from the range holding the tab character, so
  -- styling only the leading run silently falls back to 28pt default stops.
  -- A right stop ends text at location, which must clear the widest title.
  local incidentPS = {tabStops={{location=430, tabStopType="right"}}}
  local entries = {}
  for _, incident in ipairs(incidentsData) do
    local startTs = incidentStart(incident)
    local age = incident.resolved_at
      and (startTs and humanDuration(os.time() - startTs) or "?")
      or "now"
    local secs = incidentDuration(incident)
    local font = {name = incident.impact == "critical" and bold or INCIDENT_FONT_NAME,
                  size = INCIDENT_FONT_SIZE}
    local title =
      hs.styledtext.new(
        "  " .. fitIncidentTitle(incident.name or "Untitled incident", font),
        {color=impactColor(incident.impact, dim), font=font, paragraphStyle=incidentPS})
      .. hs.styledtext.new(
        "\t" .. age .. (secs and (" · " .. humanDuration(secs)) or ""),
        {color=dim, font={name=INCIDENT_FONT_NAME, size=INCIDENT_FONT_SIZE},
         paragraphStyle=incidentPS})
    local link = incident.shortlink
    table.insert(entries, {
      title    = title,
      fn       = link and function() hs.urlevent.openURL(link) end or nil,
      disabled = link == nil,
    })
  end
  table.insert(entries, {title="-"})
  table.insert(entries, {title="Open status.claude.com",
    fn=function() hs.urlevent.openURL("https://status.claude.com") end})
  return entries
end

local function buildMenu()
  local lc   = labelColor()
  local dim  = lc.white > 0.5 and {white=0.55, alpha=0.85} or {white=0.45, alpha=0.85}
  local bold = ".AppleSystemUIFontBold"
  local tabPS = {tabStops={{location=88, alignment="left"}}}

  local items = {}
  local function add(title, opts)
    local item = {title=title}
    if opts then for k, v in pairs(opts) do item[k] = v end end
    table.insert(items, item)
  end
  local function sep() table.insert(items, {title="-"}) end

  -- ── Header ──────────────────────────────────────────────────────────
  local header = hs.styledtext.new("Plan usage limits", {font={name=bold, size=13}, color=lc})
  if planName then
    header = header .. hs.styledtext.new("  " .. planName,
      {font={name=bold, size=13}, color=SESSION_CLR})
  end
  if lastData and type(lastData.extra_usage) == "table" and lastData.extra_usage.is_enabled then
    header = header .. hs.styledtext.new("+", {font={name=bold, size=13}, color=AMBER})
  end
  add(header, {disabled=true})
  sep()

  if fetchError then
    add(hs.styledtext.new("⚠  " .. fetchError,
      {color={red=0.85, green=0.3, blue=0.2}}), {disabled=true})
  elseif not lastData then
    add(hs.styledtext.new("Fetching…", {color=dim}), {disabled=true})
  else
    local d = lastData

    -- ── Session ─────────────────────────────────────────────────────
    add(hs.styledtext.new("SESSION", {font={name=bold, size=10}, color=SESSION_CLR}),
        {disabled=true})
    if d.five_hour then
      local p  = math.max(0, d.five_hour.utilization or 0)
      local tp = timeRemainingPct(d.five_hour.resets_at, FIVE_HOUR_SECS)
      add(hs.styledtext.new("  Current\t", {color=lc, paragraphStyle=tabPS})
        .. styledBlockBar(p, SESSION_CLR, 14)
        .. hs.styledtext.new(string.format("  %d%% used", math.floor(p)), {color=lc}),
        {disabled=true})
      add(hs.styledtext.new("  Time left\t", {color=dim, paragraphStyle=tabPS})
        .. styledBlockBarFlat(tp, SAGE_CLR, 14)
        .. hs.styledtext.new(string.format("  %s", formatCountdown(d.five_hour.resets_at)), {color=dim}),
        {disabled=true})
      add(hs.styledtext.new(
        string.format("  Resets %s",
          formatReset(d.five_hour.resets_at)),
        {color=dim}), {disabled=true})
    else
      add(hs.styledtext.new("  No data", {color=dim}), {disabled=true})
    end
    sep()

    -- ── Weekly ──────────────────────────────────────────────────────
    add(hs.styledtext.new("WEEKLY", {font={name=bold, size=10}, color=WEEKLY_CLR}),
        {disabled=true})
    if d.seven_day then
      local p  = math.max(0, d.seven_day.utilization or 0)
      local tp = timeRemainingPct(d.seven_day.resets_at, SEVEN_DAY_SECS)
      add(hs.styledtext.new("  All models\t", {color=lc, paragraphStyle=tabPS})
        .. styledBlockBar(p, WEEKLY_CLR, 14)
        .. hs.styledtext.new(string.format("  %d%% used", math.floor(p)), {color=lc}),
        {disabled=true})
      add(hs.styledtext.new("  Time left\t", {color=dim, paragraphStyle=tabPS})
        .. styledBlockBarFlat(tp, SAGE_CLR, 14)
        .. hs.styledtext.new(string.format("  %s", formatCountdown(d.seven_day.resets_at)), {color=dim}),
        {disabled=true})
      add(hs.styledtext.new(
        string.format("  Resets %s",
          formatReset(d.seven_day.resets_at)),
        {color=dim}), {disabled=true})
    else
      add(hs.styledtext.new("  No data", {color=dim}), {disabled=true})
    end

    local models = {}
    if d.seven_day_opus   and d.seven_day_opus.utilization   then
      table.insert(models, string.format("Opus %d%%",   math.floor(d.seven_day_opus.utilization)))
    end
    if d.seven_day_sonnet and d.seven_day_sonnet.utilization then
      table.insert(models, string.format("Sonnet %d%%", math.floor(d.seven_day_sonnet.utilization)))
    end
    if #models > 0 then
      add(hs.styledtext.new("  " .. table.concat(models, "  ·  "), {color=dim}), {disabled=true})
    end

    -- ── Additional features ─────────────────────────────────────────
    if d.extra_usage and type(d.extra_usage) == "table" then
      local ex = d.extra_usage
      local runsUsed  = ex.routine_runs and ex.routine_runs.used
      local _rl = ex.routine_runs and ex.routine_runs.limit
      local runsLimit = (_rl == nil) and 5 or _rl
      if runsUsed ~= nil then
        sep()
        add(hs.styledtext.new("ADDITIONAL FEATURES",
          {font={name=bold, size=10}, color=lc}), {disabled=true})
        local rPct = runsLimit > 0 and (runsUsed / runsLimit * 100) or 0
        add(hs.styledtext.new("  Daily routine runs\t", {color=lc, paragraphStyle=tabPS})
          .. styledBlockBar(rPct, ROUTINE_CLR, 14)
          .. hs.styledtext.new(
               string.format("  %d / %d", math.floor(runsUsed), math.floor(runsLimit)),
               {color=lc}),
          {disabled=true})
      end
    end
  end

  -- ── Claude status ───────────────────────────────────────────────────
  -- Rendered outside the usage branches above: service health is independent of
  -- whether the usage fetch succeeded, and status.claude.com has itself been the
  -- subject of an incident.
  sep()
  local statusPS = {tabStops={{location=24,  alignment="left"},
                              {location=176, alignment="left"}}}
  local statusHeader = hs.styledtext.new("STATUS", {font={name=bold, size=10}, color=lc})
  if statusData and type(statusData.status) == "table" and statusData.status.description then
    statusHeader = statusHeader .. hs.styledtext.new(
      "  " .. statusData.status.description,
      {font={name=bold, size=10},
       color=INDICATOR_COLOR[statusData.status.indicator] or lc})
  end
  add(statusHeader, {disabled=true})

  if statusData and type(statusData.components) == "table" then
    for _, component in ipairs(statusData.components) do
      if not component.group then
        local state = componentState(component.status)
        local row = hs.styledtext.new("  " .. state.glyph,
                      {color=state.color, paragraphStyle=statusPS})
          .. hs.styledtext.new("\t" .. shortComponentName(component.name),
                               {color=lc, paragraphStyle=statusPS})
        if component.status ~= "operational" then
          local since = componentSince(component)
          row = row .. hs.styledtext.new(
            "\t" .. state.label .. (since and (" · " .. since) or ""),
            {color=state.color, paragraphStyle=statusPS})
        end
        add(row, {disabled=true})
      end
    end
  end

  if statusError then
    local lastOk = statusFetchTime
      and (" · last ok " .. humanDuration(os.time() - statusFetchTime) .. " ago") or ""
    add(hs.styledtext.new("  " .. statusError .. lastOk, {color=dim}), {disabled=true})
  elseif not statusData then
    add(hs.styledtext.new("  Fetching…", {color=dim}), {disabled=true})
  end

  if incidentsError then
    add(hs.styledtext.new("  " .. incidentsError, {color=dim}), {disabled=true})
  elseif incidentsData and #incidentsData == 0 then
    add(hs.styledtext.new("  No recent incidents", {color=dim}), {disabled=true})
  elseif incidentsData then
    local stats = incidentStats(incidentsData)
    add(hs.styledtext.new(string.format("  %d incident%s in 7d · ~%s degraded",
      stats.weekCount, stats.weekCount == 1 and "" or "s",
      humanDuration(stats.weekSecs)), {color=dim}), {disabled=true})
    if stats.critical > 0 or stats.major > 0 then
      add(hs.styledtext.new(string.format("  %d critical · %d major in %dd",
        stats.critical, stats.major, stats.windowDays), {color=dim}), {disabled=true})
    end
    add(hs.styledtext.new("  Past incidents", {color=lc}),
        {menu=buildIncidentSubmenu(dim, bold)})
  end

  -- ── Footer ──────────────────────────────────────────────────────────
  sep()
  if lastFetchTime then
    add(hs.styledtext.new(
      "Updated " .. humanDuration(os.time() - lastFetchTime) .. " ago",
      {color=dim}), {disabled=true})
  end
  local rlSecs = math.ceil(rateLimitedUntil - os.time())
  if rlSecs > 0 then
    add(hs.styledtext.new("Rate limited — retry in " .. humanDuration(rlSecs),
      {color=dim}), {disabled=true})
  elseif isFetching then
    add(hs.styledtext.new("Fetching…", {color=dim}), {disabled=true})
  else
    add("Refresh now", {fn=function()
      obj:fetch()
      fetchStatus()
      fetchIncidents()
    end})
  end

  return items
end

-- ── Token refresh ──────────────────────────────────────────────────────

local isRefreshing = false

-- usedRefreshToken is the refresh token we sent to the token endpoint.
-- We re-read the file immediately before writing to detect whether Claude Code
-- already did its own refresh while our HTTP round-trip was in flight.
-- Returns true if the token was saved, false otherwise. Callers must not
-- retry the fetch when false — the file is missing or stale-checked out.
local function saveRefreshedToken(usedRefreshToken, newAccess, newRefresh, expiresIn)
  local f = io.open(CREDS_PATH, "r")
  if not f then
    print("[ClaudeUsage] cannot save refreshed token: credentials file not found")
    return false
  end
  local raw = f:read("*a"); f:close()
  local ok, creds = pcall(hs.json.decode, raw)
  if not (ok and creds and creds.claudeAiOauth) then return false end

  local oauth = creds.claudeAiOauth

  -- If the refresh token in the file has rotated, another process (Claude Code
  -- daemon) already completed a refresh. Our result is stale — do not write.
  if oauth.refreshToken and oauth.refreshToken ~= usedRefreshToken then
    print("[ClaudeUsage] skipping token write: refresh token already rotated by another process")
    return false
  end

  -- If the file already carries a later expiry than we would write, another
  -- process refreshed with a longer-lived result. Preserve theirs.
  local newExpiresAt = expiresIn and math.floor((os.time() + expiresIn) * 1000)
  if newExpiresAt and oauth.expiresAt and oauth.expiresAt > newExpiresAt then
    print("[ClaudeUsage] skipping token write: file already has a newer expiry")
    return false
  end

  oauth.accessToken = newAccess
  if newRefresh    then oauth.refreshToken = newRefresh end
  if newExpiresAt  then oauth.expiresAt    = newExpiresAt end
  local newJson = hs.json.encode(creds)
  if not newJson then return false end
  -- Write to a sibling temp file then rename so a crash mid-write never truncates
  -- the live credentials file. os.rename is atomic on the same filesystem.
  -- Intentionally not writing to the Keychain: the Keychain entry is owned by
  -- Claude Code; passing a token as a CLI argument would expose it in `ps`.
  local tmp = CREDS_PATH .. ".tmp"
  local fw = io.open(tmp, "w")
  if not fw then return false end
  local wok = fw:write(newJson)
  fw:close()
  if not wok then os.remove(tmp); return false end
  os.execute("chmod 600 " .. shellQuote(tmp))
  if not os.rename(tmp, CREDS_PATH) then os.remove(tmp); return false end
  return true
end

local function doTokenRefresh(refreshTok)
  if isRefreshing then return end
  if not menubar then return end
  isRefreshing = true
  menubar:setTitle("↻")
  local function urlEncode(s)
    return s:gsub("[^%w%-._~]", function(c) return string.format("%%%02X", c:byte()) end)
  end
  local body = "grant_type=refresh_token&refresh_token=" .. urlEncode(refreshTok) .. "&client_id=" .. urlEncode(getClientId())
  hs.http.asyncPost(TOKEN_URL, body,
    {["Content-Type"] = "application/x-www-form-urlencoded",
     ["User-Agent"]   = getUserAgent()},
    function(status, respBody, _)
      isRefreshing = false
      if not menubar then return end  -- stop() fired while request was in-flight
      if status == 200 then
        local ok, parsed = pcall(hs.json.decode, respBody)
        if ok and parsed then
          local newAccess  = parsed.access  or parsed.access_token  or parsed.accessToken
          local newRefresh = parsed.refresh or parsed.refresh_token or parsed.refreshToken
          if newAccess then
            print("[ClaudeUsage] token refreshed successfully")
            local saved = saveRefreshedToken(refreshTok, newAccess, newRefresh, parsed.expires_in)
            tsCache = {}
            if saved then
              obj:fetch()
            else
              fetchError = "Token refreshed but could not be saved — run 'claude' to re-authenticate"
              if menubar then menubar:setIcon(); menubar:setTitle("⚠") end
            end
            return
          end
        end
      end
      print(string.format("[ClaudeUsage] token refresh failed HTTP %d: %s", status, tostring(respBody):sub(1, 200)))
      local ok2, e = pcall(hs.json.decode, respBody)
      if ok2 and e and e.error == "invalid_grant" then
        fetchError = "Session expired — waiting for Claude Code to re-authenticate"
      else
        fetchError = string.format("Token refresh failed (HTTP %d) — run 'claude' to re-authenticate", status)
      end
      menubar:setIcon(); menubar:setTitle("⚠")
    end)
end

-- ── Fetch ──────────────────────────────────────────────────────────────

-- Status failures are kept out of fetchError and never set the ⚠ title, which
-- stays reserved for usage and auth problems. Stale component data is left on
-- screen with the error noting how long ago it was last confirmed.
function fetchStatus()
  statusAttemptTime = os.time()
  hs.http.asyncGet(STATUS_URL, {["User-Agent"] = getUserAgent()},
    function(status, body, _)
      if not menubar then return end  -- stop() fired while request was in-flight
      if status ~= 200 then
        print(string.format("[ClaudeUsage] status fetch HTTP %d", status))
        statusError = string.format("status page unavailable (HTTP %d)", status)
        return
      end
      local ok, parsed = pcall(hs.json.decode, body)
      if not (ok and type(parsed) == "table" and type(parsed.components) == "table") then
        statusError = "status page returned unexpected data"
        return
      end
      statusData      = parsed
      statusFetchTime = os.time()
      statusError     = nil
      refreshIcon()
    end)
end

function fetchIncidents()
  incidentsAttemptTime = os.time()
  hs.http.asyncGet(INCIDENTS_URL, {["User-Agent"] = getUserAgent()},
    function(status, body, _)
      if not menubar then return end
      if status ~= 200 then
        print(string.format("[ClaudeUsage] incidents fetch HTTP %d", status))
        incidentsError = "incident history unavailable"
        return
      end
      local ok, parsed = pcall(hs.json.decode, body)
      if not (ok and type(parsed) == "table" and type(parsed.incidents) == "table") then
        incidentsError = "incident history returned unexpected data"
        return
      end
      incidentsData  = parsed.incidents
      incidentsError = nil
    end)
end

--- ClaudeUsage:fetch()
--- Method
--- Immediately fetches current usage from the Anthropic API and updates the
--- menu bar icon and dropdown. Called automatically on start and by the poll
--- timer; can also be triggered manually via the "Refresh now" menu item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
function obj:fetch()
  if isFetching then return end
  if os.time() < rateLimitedUntil then return end
  isFetching = true

  local token, pd, err, rt = resolveToken()
  if pd then planName = pd end

  if not token then
    print("[ClaudeUsage] no token, err=" .. tostring(err))
    if err == "expired" then
      if obj.autoRefreshToken and rt then
        isFetching = false  -- must clear before handing off; doTokenRefresh calls fetch() on completion
        doTokenRefresh(rt)
        return
      end
      fetchError = "Token expired — waiting for Claude Code to refresh"
    elseif err == "no_file" then
      fetchError = "Credentials not found: " .. CREDS_PATH
    else
      fetchError = "No token found in credentials file"
    end
    if menubar then menubar:setIcon(); menubar:setTitle("⚠") end
    isFetching = false
    return
  end

  hs.http.asyncGet(USAGE_URL, {
    ["Authorization"]  = "Bearer " .. token,
    ["anthropic-beta"] = getOauthBeta(),
    ["User-Agent"]     = getUserAgent(),
  }, function(status, body, headers)
    isFetching = false
    if not menubar then return end  -- stop() fired while request was in-flight
    if status == 200 then
      local ok, parsed = pcall(hs.json.decode, body)
      if ok and parsed then
        lastData      = parsed
        lastFetchTime = os.time()
        fetchError    = nil
        refreshIcon()
      else
        fetchError = "Bad response from server"
        menubar:setIcon(); menubar:setTitle("⚠")
      end
    elseif status == 429 then
      local _ra = tonumber(headers and (headers["Retry-After"] or headers["retry-after"]))
      local retryAfter = math.min((_ra == nil) and obj.pollInterval or _ra, 3600)
      rateLimitedUntil = os.time() + retryAfter
      print(string.format("[ClaudeUsage] HTTP 429 rate limited, retry in %ds", retryAfter))
      menubar:setIcon(); menubar:setTitle("⚠")
    elseif status == 401 then
      print("[ClaudeUsage] HTTP 401 auth error: " .. tostring(body):sub(1, 200))
      fetchError = "Auth failed — re-open Claude Code to refresh token"
      menubar:setIcon(); menubar:setTitle("⚠")
    else
      print(string.format("[ClaudeUsage] HTTP %d error: %s", status, tostring(body):sub(1, 200)))
      fetchError = string.format("HTTP %d from usage endpoint", status)
      menubar:setIcon(); menubar:setTitle("⚠")
    end
  end)
end

-- ── Lifecycle ──────────────────────────────────────────────────────────

--- ClaudeUsage:init()
--- Method
--- Prepares the menu bar item. Called automatically by hs.loadSpoon(); do not
--- call manually. Does not start background polling or make any network requests.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
function obj:init()
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  menubar:setTitle("…")
  menubar:setMenu(buildMenu)
  return self
end

--- ClaudeUsage:start()
--- Method
--- Starts background polling. Performs an immediate fetch then schedules
--- subsequent fetches every ClaudeUsage.pollInterval seconds.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
function obj:start()
  if timer then timer:stop(); timer = nil end
  self:fetch()
  fetchStatus()
  fetchIncidents()
  timer = hs.timer.new(obj.pollInterval, function()
    self:fetch()
    local now = os.time()
    if now - (statusAttemptTime or 0) >= obj.statusPollInterval then
      fetchStatus()
    end
    if now - (incidentsAttemptTime or 0) >= obj.incidentsPollInterval then
      fetchIncidents()
    end
  end)
  timer:start()
  return self
end

--- ClaudeUsage:stop()
--- Method
--- Stops background polling and removes the menu bar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
function obj:stop()
  if timer   then timer:stop();     timer   = nil end
  if menubar then menubar:delete(); menubar = nil end
  lastData, lastFetchTime, fetchError, planName = nil, nil, nil, nil
  statusData, statusFetchTime, statusError, statusAttemptTime = nil, nil, nil, nil
  incidentsData, incidentsError, incidentsAttemptTime = nil, nil, nil
  tsCache          = {}
  isFetching       = false
  rateLimitedUntil = 0
  isRefreshing     = false
  _cachedBinPath, _cachedClientId, _cachedUserAgent, _cachedOauthBeta = nil, nil, nil, nil
  return self
end

return obj
