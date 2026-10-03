--- === GeminiUsage ===
---
--- Displays Google Gemini and partner AI plan usage limits in a single unified macOS menu bar item.
--- The icon renders a dual-column layout side-by-side:
---   * Left column: Gemini models (5-hour session and weekly progress bars).
---   * Right column: Claude & 3P partner models (5-hour session and weekly progress bars).
---
--- Features 8-segment gradient progress bars with sqrt-scaled reset proximity countdown lines,
--- usage percentages, and a service health indicator dot. Clicking the menu bar item expands
--- a rich dropdown detailing quota usage for both pools, countdowns, reset times in the local
--- timezone, session context window metrics, Google Cloud / Vertex AI service health, and
--- a model roster.
---
--- Credentials and quota data are automatically resolved from Antigravity CLI (`agy`), macOS
--- Keychain, local quota cache files, and Google Cloud endpoints.

local obj = {}
obj.__index = obj

--- GeminiUsage.name
--- Constant
--- The name of this Spoon
obj.name = "GeminiUsage"

--- GeminiUsage.version
--- Constant
--- The version of this Spoon
obj.version = "1.0"

--- GeminiUsage.author
--- Constant
--- The author of this Spoon
obj.author = "Facing Quantum <111430155+facing-quantum@users.noreply.github.com>"

--- GeminiUsage.license
--- Constant
--- The license for this Spoon (MIT)
obj.license = "MIT"

--- GeminiUsage.homepage
--- Constant
--- The homepage for this Spoon
obj.homepage = "https://github.com/Hammerspoon/Spoons"

--- GeminiUsage.pollInterval
--- Variable
--- Seconds between quota and usage data checks. Default 120.
obj.pollInterval = 120

--- GeminiUsage.statusPollInterval
--- Variable
--- Minimum seconds between Google service status fetches. Default 300.
obj.statusPollInterval = 300

--- GeminiUsage.incidentsPollInterval
--- Variable
--- Minimum seconds between Google incident history fetches. Default 900.
obj.incidentsPollInterval = 900

--- GeminiUsage.modelsPollInterval
--- Variable
--- Minimum seconds between model roster updates. Default 3600.
obj.modelsPollInterval = 3600

--- GeminiUsage.iconStyle
--- Variable
--- Menu bar icon display style: "dual" (default, both Gemini and Claude side-by-side in one icon),
--- "split" (top bar Gemini 5h, bottom bar Claude 5h), or "active" (active model family 5h and weekly).
obj.iconStyle = "dual"

--- GeminiUsage.agyBinPaths
--- Variable
--- Extra locations to search for the `agy` or `gemini` binary, tried in order
--- before PATH lookup. Accepts a string or a table of strings. Default {}.
obj.agyBinPaths = {}

--- GeminiUsage.geminiApiKey
--- Variable
--- Optional Google AI Studio API key. If unset, the spoon checks the GEMINI_API_KEY
--- environment variable or Keychain/OAuth credentials. Default nil.
obj.geminiApiKey = nil

--- GeminiUsage.quotaCachePath
--- Variable
--- Path to check for cached statusline quota JSON.
--- Default `~/.gemini/antigravity-cli/cache/quota_state.json`.
obj.quotaCachePath = os.getenv("HOME") .. "/.gemini/antigravity-cli/cache/quota_state.json"

--- GeminiUsage.planName
--- Variable
--- Plan or subscription tier display name override. Default nil (auto-resolved).
obj.planName = nil

local menubar, timer, resetTimer
local lastData, lastFetchTime, fetchError, planName
local statusData, statusFetchTime, statusError, statusAttemptTime
local incidentsData, incidentsError, incidentsAttemptTime
local modelsData, modelsFetchTime, modelsError, modelsAttemptTime
local isFetching = false

-- ── Color Palette ──────────────────────────────────────────────────────

local GEMINI_SESSION_CLR = {red=0.259, green=0.522, blue=0.957, alpha=1}  -- Gemini Azure  #4285F4
local GEMINI_WEEKLY_CLR  = {red=0.482, green=0.380, blue=1.000, alpha=1}  -- Gemini Violet #7B61FF
local CLAUDE_SESSION_CLR = {red=0.851, green=0.467, blue=0.337, alpha=1}  -- Claude Coral  #D97756
local CLAUDE_WEEKLY_CLR  = {red=0.769, green=0.635, blue=0.349, alpha=1}  -- Golden Tan    #C4A259
local ROUTINE_CLR        = {red=0.106, green=0.631, blue=0.886, alpha=1}  -- Cyan Accent   #1BA1E2
local SAGE_CLR           = {red=0.400, green=0.620, blue=0.480, alpha=1}  -- Sage Green    #66A07A
local WARN_RED           = {red=0.851, green=0.188, blue=0.145, alpha=1}  -- Warning Red   #D93025
local AMBER              = {red=0.976, green=0.671, blue=0.000, alpha=1}  -- Amber Warning #F9AB00

local function lerpColor(a, b, t)
  return {red   = a.red   + (b.red   - a.red)   * t,
          green = a.green + (b.green - a.green) * t,
          blue  = a.blue  + (b.blue  - a.blue)  * t,
          alpha = a.alpha + (b.alpha - a.alpha) * t}
end

local function barColor(base, pct)
  return lerpColor(base, WARN_RED, math.max(0, math.min(1, (pct - 70) / 25)))
end

local function labelColor()
  return (hs.host.interfaceStyle() == "Dark")
    and {white=0.85, alpha=0.9} or {white=0.1, alpha=0.9}
end

-- ── Backoff ────────────────────────────────────────────────────────────

local backoffUntil    = 0
local backoffFailures = 0
local backoffReason   = nil
local BACKOFF_CAP     = 3600

local BACKOFF_LABEL = {
  ratelimit = "Rate limited",
  network   = "Connection failed",
  server    = "Server error",
}

local function backoffSeconds(failures, floor)
  local growth   = 2 ^ math.max(0, failures - 1)
  local nominal  = math.max(obj.pollInterval, floor or 0) * growth
  local jittered = math.floor(math.min(nominal, BACKOFF_CAP) * (0.9 + math.random() * 0.2))
  return math.min(math.max(jittered, floor or 0), BACKOFF_CAP)
end

local function enterBackoff(reason, atLeast)
  backoffFailures = backoffFailures + 1
  local secs = backoffSeconds(backoffFailures, atLeast)
  backoffUntil  = os.time() + secs
  backoffReason = reason
  return secs
end

local function clearBackoff()
  backoffFailures = 0
  backoffUntil    = 0
  backoffReason   = nil
end

-- ── Endpoints ──────────────────────────────────────────────────────────

local GCLOUD_STATUS_URL     = "https://status.cloud.google.com/incidents.json"
local GCLOUD_SERVICES_URL   = "https://status.cloud.google.com/services.json"
local WORKSPACE_STATUS_URL  = "https://www.google.com/appsstatus/dashboard/incidents.json"
local CODE_ASSIST_URL       = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
local MODEL_DOCS_URL        = "https://ai.google.dev/gemini-api/docs/models/gemini"

-- Assigned in the Fetch section; declared here for menu callbacks
local fetchStatus, fetchIncidents, fetchModels, fetchPlan

-- ── Time & Date Helpers ────────────────────────────────────────────────

local function daysFromCivil(year, month, day)
  local y = (month <= 2) and (year - 1) or year
  local era = math.floor(y / 400)
  local yearOfEra = y - era * 400
  local dayOfYear = math.floor((153 * ((month > 2) and (month - 3) or (month + 9)) + 2) / 5) + day - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

local function utcIsoToUnix(iso)
  if not iso or type(iso) ~= "string" then return nil end
  if iso:match("^%d+$") then return tonumber(iso) end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    h, mi, s = 0, 0, 0
  end
  if not y then return nil end
  local epochSecs = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
                  + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
  local sign, offH, offM = iso:match("([+-])(%d%d):(%d%d)$")
  if sign then
    local offsetSecs = tonumber(offH) * 3600 + tonumber(offM) * 60
    epochSecs = epochSecs + ((sign == "+") and -offsetSecs or offsetSecs)
  end
  return epochSecs
end

local function humanDuration(secs)
  if not secs or secs < 0 then return "0m" end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  if d > 0 then
    return string.format("%dd %dh", d, h)
  elseif h > 0 then
    return string.format("%dh %dm", h, m)
  elseif m > 0 then
    return string.format("%dm", m)
  else
    return "<1m"
  end
end

local function formatCountdown(val)
  if not val then return "--" end
  local targetTs = (type(val) == "number" and val >= 100000000) and val or utcIsoToUnix(val)
  if not targetTs then return "--" end
  local diff = targetTs - os.time()
  if diff <= 0 then return "ready" end
  return humanDuration(diff)
end

local function formatReset(val)
  if not val then return "soon" end
  local targetTs = (type(val) == "number" and val >= 100000000) and val or utcIsoToUnix(val)
  if not targetTs then return "soon" end
  local diff = targetTs - os.time()
  if diff <= 0 then
    local targetDate = os.date("*t", targetTs)
    local nowDate    = os.date("*t", os.time())
    local isToday    = (targetDate.year == nowDate.year and targetDate.yday == nowDate.yday)
    local timeStr    = os.date("%I:%M %p", targetTs):gsub("^0", "")
    if isToday then
      return string.format("reset at %s (ready)", timeStr)
    elseif (nowDate.year == targetDate.year and nowDate.yday - targetDate.yday == 1) then
      return string.format("reset yesterday at %s (ready)", timeStr)
    else
      return "reset (ready)"
    end
  end

  local targetDate = os.date("*t", targetTs)
  local nowDate    = os.date("*t", os.time())
  local isToday    = (targetDate.year == nowDate.year and targetDate.yday == nowDate.yday)
  local isTomorrow = (targetTs - os.time() < 86400 * 2 and targetDate.yday == (nowDate.yday + 1))

  local timeStr = os.date("%I:%M %p", targetTs):gsub("^0", "")
  if isToday then
    return string.format("at %s", timeStr)
  elseif isTomorrow then
    return string.format("tomorrow at %s", timeStr)
  elseif diff < 7 * 86400 then
    return string.format("%s at %s", os.date("%A", targetTs), timeStr)
  else
    return string.format("%s at %s", os.date("%b %d", targetTs), timeStr)
  end
end

local function timeRemainingPct(val, maxSecs)
  if not val then return 100 end
  local targetTs = (type(val) == "number" and val >= 100000000) and val or utcIsoToUnix(val)
  if not targetTs then return 100 end
  local rem = targetTs - os.time()
  if rem <= 0 then return 0 end
  local linear = math.min(1, rem / (maxSecs or 18000))
  return math.sqrt(linear) * 100
end

local function getQuotaResetVal(q, cacheMtime)
  if not q then return nil end
  -- 1. Prefer absolute ISO timestamp: q.reset_time
  if q.reset_time and type(q.reset_time) == "string" and q.reset_time ~= "" then
    local ts = utcIsoToUnix(q.reset_time)
    if ts then return ts end
  end
  -- 2. Epoch timestamp number
  if type(q.reset_time) == "number" and q.reset_time >= 100000000 then
    return q.reset_time
  end
  -- 3. Relative seconds (reset_in_seconds) anchored to cache mtime
  if q.reset_in_seconds then
    local sec = tonumber(q.reset_in_seconds)
    if sec then
      if sec >= 100000000 then
        return sec
      end
      local base = cacheMtime or (lastData and lastData._cacheMtime) or (lastFetchTime or os.time())
      return base + sec
    end
  end
  return nil
end

local function getQuotaPct(q, resetTs)
  if not q then return 0 end
  local rTs = resetTs or getQuotaResetVal(q)
  if rTs and rTs <= os.time() then
    return 0
  end
  if q.remaining_fraction ~= nil then
    return math.max(0, math.min(100, math.floor((1.0 - q.remaining_fraction) * 100 + 0.5)))
  end
  if q.utilization ~= nil then
    return math.max(0, math.min(100, math.floor(q.utilization + 0.5)))
  end
  if q.used_percentage ~= nil then
    return math.max(0, math.min(100, math.floor(q.used_percentage + 0.5)))
  end
  return 0
end

local function extractPlanName(data, override)
  if override and override ~= "" then
    return override
  end
  if not data then return nil end

  -- 1. Check direct plan_tier field (e.g. from agy StatusLineData)
  if type(data.plan_tier) == "string" and data.plan_tier ~= "" then
    return data.plan_tier
  end

  -- 2. Check paidTier from Google Code Assist API response
  local pt = data.paidTier or data.paid_tier
  if type(pt) == "table" then
    if type(pt.name) == "string" and pt.name ~= "" then
      return pt.name
    end
    if pt.id == "g1-pro-tier" then
      return "Google AI Pro"
    elseif pt.id == "g1-ultra-tier" then
      return "Google AI Ultra"
    end
  end

  -- 3. Check g1Tier / g1_tier
  local g1 = data.g1Tier or data.g1_tier
  if type(g1) == "string" and g1 ~= "" then
    return g1
  end

  -- 4. Check explicit plan or tier if not generic "antigravity"
  if type(data.plan) == "string" and data.plan ~= "" and data.plan:lower() ~= "antigravity" then
    return data.plan
  end
  if type(data.tier) == "string" and data.tier ~= "" and data.tier:lower() ~= "antigravity" and data.tier:lower() ~= "free-tier" then
    return data.tier
  end

  -- 5. Check allowedTiers for standard / enterprise tiers
  local tiers = data.allowedTiers or data.allowed_tiers
  if type(tiers) == "table" then
    for _, t in ipairs(tiers) do
      if t.id == "standard-tier" and not t.isDefault then
        return "Gemini Code Assist Standard"
      elseif t.id == "enterprise-tier" then
        return "Gemini Code Assist Enterprise"
      end
    end
  end

  -- 6. Check currentTier
  local ct = data.currentTier or data.current_tier
  if type(ct) == "table" and ct.name and ct.name:lower() ~= "antigravity" then
    return ct.name
  end

  if type(data.product) == "string" and data.product ~= "" then
    return "Antigravity"
  end

  return nil
end

-- ── Binary & Tool Discovery ────────────────────────────────────────────

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fileExists(path)
  return path ~= "" and hs.fs.attributes(path, "mode") ~= nil
end

local function isCompleteObject(text)
  return text:sub(1, 1) == "{" and text:sub(-1) == "}"
end

-- agy rewrites its cache/statusline files from another process without truncating them,
-- so a read can land mid-write, or a shorter one-line object can be followed by the stale
-- tail of the previous write. Decode only a complete object instead of letting
-- hs.json.decode log a LuaSkin error to the console on every poll.
local function readJsonFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  local trimmed = raw:match("^%s*(.-)%s*$")
  local firstLine = trimmed:match("^[^\n]*"):match("^(.-)%s*$")
  if isCompleteObject(firstLine) then trimmed = firstLine end
  if not isCompleteObject(trimmed) then return nil end
  local ok, parsed = pcall(hs.json.decode, trimmed)
  if ok and type(parsed) == "table" then return parsed end
  return nil
end
obj._readJsonFile = readJsonFile

local function findAgyBinary()
  local candidates = {}
  local conf = obj.agyBinPaths
  if type(conf) == "string" then table.insert(candidates, conf) end
  if type(conf) == "table" then
    for _, p in ipairs(conf) do table.insert(candidates, p) end
  end
  table.insert(candidates, "/usr/local/lib/ai-workspace/agent-bin/agy")
  table.insert(candidates, "/usr/local/bin/agy")
  table.insert(candidates, "/opt/homebrew/bin/agy")
  table.insert(candidates, os.getenv("HOME") .. "/.local/bin/agy")
  table.insert(candidates, os.getenv("HOME") .. "/bin/agy")

  for _, path in ipairs(candidates) do
    if fileExists(path) then return path end
  end

  local ok, out = pcall(hs.execute, "command -v agy 2>/dev/null", true)
  if ok and type(out) == "string" and out:match("^/") then
    return out:gsub("%s+$", "")
  end
  return nil
end

-- ── Credentials & Quota Resolution ─────────────────────────────────────

local function getAgyKeychainToken()
  local services = {"antigravity", "antigravity-oauth-token", "Gemini-credentials"}
  for _, s in ipairs(services) do
    local cmd = string.format('security find-generic-password -s %s -w 2>/dev/null', shellQuote(s))
    local raw = hs.execute(cmd)
    if raw and not raw:match("^%s*$") then
      local trimmed = raw:gsub("%s+$", "")
      local ok, parsed = pcall(hs.json.decode, trimmed)
      if ok and type(parsed) == "table" then
        local token = (parsed.token and parsed.token.access_token)
                   or parsed.access_token or parsed.accessToken
        if token then return token, "keychain" end
      elseif #trimmed > 20 then
        return trimmed, "keychain"
      end
    end
  end
  return nil, nil
end

local function getAgyFileToken()
  local paths = {
    os.getenv("HOME") .. "/.gemini/antigravity-cli/antigravity-oauth-token",
    os.getenv("HOME") .. "/.gemini/antigravity-cli/oauth_token.json",
  }
  for _, path in ipairs(paths) do
    local f = io.open(path, "r")
    if f then
      local raw = f:read("*a"); f:close()
      local ok, parsed = pcall(hs.json.decode, raw)
      if ok and type(parsed) == "table" then
        local token = (parsed.token and parsed.token.access_token)
                   or parsed.access_token or parsed.accessToken
        if token then return token, "file" end
      end
    end
  end
  return nil, nil
end

local function resolveAuthToken()
  local token, src = getAgyKeychainToken()
  if token then return token, src end
  token, src = getAgyFileToken()
  if token then return token, src end
  local envKey = obj.geminiApiKey or os.getenv("GEMINI_API_KEY")
  if envKey and envKey ~= "" then return envKey, "env" end
  return nil, "none"
end

local function loadCachedQuota()
  local cacheCandidates = {
    obj.quotaCachePath,
    os.getenv("HOME") .. "/.gemini/antigravity-cli/cache/quota_state.json",
    "/tmp/agy-statusline-quota.json",
  }

  local bestParsed, bestMtime = nil, -1

  for _, path in ipairs(cacheCandidates) do
    if path and fileExists(path) then
      local attr = hs.fs.attributes(path)
      local mtime = (attr and attr.modification) or 0
      local parsed = readJsonFile(path)
      if parsed and (parsed.quota or parsed["gemini-5h"] or parsed.model) then
        if mtime > bestMtime then
          bestMtime = mtime
          bestParsed = parsed
        end
      end
    end
  end

  -- Check any active agy statusline input files in /tmp
  local ok, dirList = pcall(hs.fs.dir, "/tmp")
  if ok and type(dirList) == "table" then
    for _, fname in ipairs(dirList) do
      if fname:match("^agy%-statusline%-input%.") then
        local fullPath = "/tmp/" .. fname
        if fileExists(fullPath) then
          local attr = hs.fs.attributes(fullPath)
          local mtime = (attr and attr.modification) or 0
          local parsed = readJsonFile(fullPath)
          if parsed and (parsed.quota or parsed["gemini-5h"] or parsed.model) then
            if mtime > bestMtime then
              bestMtime = mtime
              bestParsed = parsed
            end
          end
        end
      end
    end
  end

  if bestParsed then
    bestParsed._cacheMtime = (bestMtime > 0) and bestMtime or os.time()
  end
  return bestParsed
end

-- ── Service Health ─────────────────────────────────────────────────────

local function incidentDuration(incident)
  local startTs = utcIsoToUnix(incident.begin or incident.created)
  if not startTs then return nil end
  local endVal = incident["end"] or incident.end_time or incident.resolved
  local endTs = (endVal and endVal ~= "" and endVal ~= "null") and utcIsoToUnix(endVal) or os.time()
  return math.max(0, endTs - startTs)
end

local function isIncidentActive(incident)
  if incident.most_recent_update and incident.most_recent_update.status == "AVAILABLE" then
    return false
  end
  local endVal = incident["end"] or incident.end_time or incident.resolved
  if endVal and endVal ~= "" and endVal ~= "null" then
    local endTs = utcIsoToUnix(endVal)
    if endTs and endTs <= os.time() then
      return false
    end
  end
  if not endVal or endVal == "" or endVal == "null" then
    return true
  end
  local endTs = utcIsoToUnix(endVal)
  return endTs and endTs > os.time()
end

local function serviceHealthDotColor()
  if not incidentsData then return nil end
  local hasOutage = false
  local hasDegraded = false
  for _, inc in ipairs(incidentsData) do
    if isIncidentActive(inc) then
      local sev = tostring(inc.severity or inc.status_impact or ""):lower()
      if sev:match("high") or sev:match("critical") or sev:match("major") then
        hasOutage = true
      else
        hasDegraded = true
      end
    end
  end
  if hasOutage then return WARN_RED end
  if hasDegraded then return AMBER end
  return SAGE_CLR
end

-- ── Model Catalog ──────────────────────────────────────────────────────

local KNOWN_GEMINI_MODELS = {
  {id="gemini-3.8-flash-high",   name="Gemini 3.8 Flash (High)",   family="gemini"},
  {id="gemini-3.8-flash-medium", name="Gemini 3.8 Flash (Medium)", family="gemini"},
  {id="gemini-3.8-flash-low",    name="Gemini 3.8 Flash (Low)",    family="gemini"},
  {id="gemini-3.7-flash-high",   name="Gemini 3.7 Flash (High)",   family="gemini"},
  {id="gemini-3.7-flash-medium", name="Gemini 3.7 Flash (Medium)", family="gemini"},
  {id="gemini-3.7-flash-low",    name="Gemini 3.7 Flash (Low)",    family="gemini"},
  {id="gemini-3.6-flash-high",   name="Gemini 3.6 Flash (High)",   family="gemini"},
  {id="gemini-3.1-pro-high",     name="Gemini 3.1 Pro (High)",     family="gemini"},
  {id="gemini-3.1-pro-low",      name="Gemini 3.1 Pro (Low)",      family="gemini"},
  {id="gemini-2.5-flash",        name="Gemini 2.5 Flash",          family="gemini"},
}

local KNOWN_3P_MODELS = {
  {id="claude-sonnet-4-6",        name="Claude Sonnet 4.6 (Thinking)", family="3p"},
  {id="claude-opus-4-6-thinking", name="Claude Opus 4.6 (Thinking)",   family="3p"},
  {id="gpt-oss-120b-medium",      name="GPT-OSS 120B (Medium)",        family="3p"},
}

local function discoverLocalModels()
  local agy = findAgyBinary()
  if not agy then return nil end
  local ok, out = pcall(hs.execute, shellQuote(agy) .. " models 2>/dev/null", true)
  if not (ok and type(out) == "string" and #out > 10) then return nil end
  local models = {}
  for line in out:gmatch("[^\r\n]+") do
    local id, display = line:match("^(%S+)%s+(.+)$")
    if id and not id:match("^⠋") and not id:match("^Fetching") then
      local family = (id:match("^claude") or id:match("^gpt")) and "3p" or "gemini"
      table.insert(models, {id=id, name=display:gsub("%s+$", ""), family=family, available=true})
    end
  end
  return #models > 0 and models or nil
end

-- ── Canvas Menu Bar Icon (Dual-Column Unified) ─────────────────────────

local function appendGradientBar(c, baseClr, pct, x0, y0, totalW, h, segCount)
  local SEGS   = segCount or 6
  local GAP    = 2.0
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

-- Renders both Gemini (left) and Claude/3P (right) columns in a single unified canvas (width 170)
local function buildDualColumnIcon(gSPct, gWPct, gSTime, gWTime, pSPct, pWPct, pSTime, pWTime, dotColor)
  gSPct = math.max(0, math.min(100, gSPct or 0))
  gWPct = math.max(0, math.min(100, gWPct or 0))
  pSPct = math.max(0, math.min(100, pSPct or 0))
  pWPct = math.max(0, math.min(100, pWPct or 0))

  local W, H, BH = 170, 26, 8
  local LABEL_W  = 28
  local BAR_W    = 46
  local c        = hs.canvas.new({x=0, y=0, w=W, h=H})

  -- Column 1: Gemini (x = 2 to 78)
  local gSc = barColor(GEMINI_SESSION_CLR, gSPct)
  local gWc = barColor(GEMINI_WEEKLY_CLR,  gWPct)

  c:appendElements({type="text", text=string.format("%d%%", math.floor(gSPct)),
    textColor=gSc, textSize=10, textAlignment="right",
    frame={x=2, y=0, w=LABEL_W, h=11}})
  appendGradientBar(c, GEMINI_SESSION_CLR, gSPct, 32, 2, BAR_W, BH, 6)
  appendThinBar    (c, SAGE_CLR, gSTime, 32, 11, BAR_W, 2)

  c:appendElements({type="text", text=string.format("%d%%", math.floor(gWPct)),
    textColor=gWc, textSize=10, textAlignment="right",
    frame={x=2, y=13, w=LABEL_W, h=11}})
  appendGradientBar(c, GEMINI_WEEKLY_CLR, gWPct, 32, 15, BAR_W, BH, 6)
  appendThinBar    (c, SAGE_CLR, gWTime, 32, 24, BAR_W, 2)

  -- Subtle vertical separator (x = 81)
  c:appendElements({type="rectangle", action="fill",
    fillColor={white=0.4, alpha=0.35},
    frame={x=81, y=3, w=1, h=20}})

  -- Column 2: Claude & 3P (x = 84 to 160)
  local pSc = barColor(CLAUDE_SESSION_CLR, pSPct)
  local pWc = barColor(CLAUDE_WEEKLY_CLR,  pWPct)

  c:appendElements({type="text", text=string.format("%d%%", math.floor(pSPct)),
    textColor=pSc, textSize=10, textAlignment="right",
    frame={x=84, y=0, w=LABEL_W, h=11}})
  appendGradientBar(c, CLAUDE_SESSION_CLR, pSPct, 114, 2, BAR_W, BH, 6)
  appendThinBar    (c, SAGE_CLR, pSTime, 114, 11, BAR_W, 2)

  c:appendElements({type="text", text=string.format("%d%%", math.floor(pWPct)),
    textColor=pWc, textSize=10, textAlignment="right",
    frame={x=84, y=13, w=LABEL_W, h=11}})
  appendGradientBar(c, CLAUDE_WEEKLY_CLR, pWPct, 114, 15, BAR_W, BH, 6)
  appendThinBar    (c, SAGE_CLR, pWTime, 114, 24, BAR_W, 2)

  -- Service Health Indicator Dot (x = 165)
  if dotColor then
    c:appendElements({type="circle", action="fill", fillColor=dotColor,
      center={x=165, y=13}, radius=3})
  end

  local img = c:imageFromCanvas()
  img:template(false)
  c:delete()
  return img
end

local function scheduleNextReset(tsList)
  local now = os.time()
  local soonest = nil
  for _, ts in ipairs(tsList) do
    if ts and ts > now then
      if not soonest or ts < soonest then
        soonest = ts
      end
    end
  end
  if resetTimer then resetTimer:stop(); resetTimer = nil end
  if soonest then
    local delay = soonest - now + 1
    if delay > 0 and delay <= 7200 then
      resetTimer = hs.timer.doAfter(delay, function()
        resetTimer = nil
        refreshIcon()
      end)
    end
  end
end

local function refreshIcon()
  if not menubar then return end
  local dot = serviceHealthDotColor()

  -- Extract Gemini Quotas
  local g5h = lastData and (lastData.quota and lastData.quota["gemini-5h"] or lastData["gemini-5h"])
  local gWk = lastData and (lastData.quota and lastData.quota["gemini-weekly"] or lastData["gemini-weekly"])
  local gSTs = getQuotaResetVal(g5h)
  local gWTs = getQuotaResetVal(gWk)
  local gSPct = getQuotaPct(g5h, gSTs)
  local gWPct = getQuotaPct(gWk, gWTs)
  local gSTime = gSTs and timeRemainingPct(gSTs, 18000) or 100
  local gWTime = gWTs and timeRemainingPct(gWTs, 604800) or 100

  -- Extract Claude / 3P Quotas
  local p5h = lastData and (lastData.quota and lastData.quota["3p-5h"] or lastData["3p-5h"])
  local pWk = lastData and (lastData.quota and lastData.quota["3p-weekly"] or lastData["3p-weekly"])
  local pSTs = getQuotaResetVal(p5h)
  local pWTs = getQuotaResetVal(pWk)
  local pSPct = getQuotaPct(p5h, pSTs)
  local pWPct = getQuotaPct(pWk, pWTs)
  local pSTime = pSTs and timeRemainingPct(pSTs, 18000) or 100
  local pWTime = pWTs and timeRemainingPct(pWTs, 604800) or 100

  scheduleNextReset({gSTs, gWTs, pSTs, pWTs})

  menubar:setIcon(buildDualColumnIcon(gSPct, gWPct, gSTime, gWTime, pSPct, pWPct, pSTime, pWTime, dot), false)
  menubar:setTitle("")
end

-- ── Dropdown Menu ──────────────────────────────────────────────────────

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

local function buildIncidentSubmenu(dim)
  local entries = {}
  if not incidentsData or #incidentsData == 0 then
    table.insert(entries, {title=hs.styledtext.new("  No active or recent incidents", {color=dim}), disabled=true})
  else
    for i, inc in ipairs(incidentsData) do
      if i > 8 then break end
      local desc = inc.external_desc or inc.service_name or "Google Cloud Incident"
      local dur = incidentDuration(inc)
      local durStr = dur and humanDuration(dur) or ""
      local active = isIncidentActive(inc)
      local clr = active and WARN_RED or dim
      local itemTitle = string.format("  %s %s (%s)", active and "✕" or "✓", desc:sub(1, 45), durStr)
      local fullUrl = inc.uri
      if fullUrl and not fullUrl:match("^https?://") then
        fullUrl = "https://status.cloud.google.com/" .. fullUrl:gsub("^/", "")
      end
      table.insert(entries, {
        title = hs.styledtext.new(itemTitle, {color=clr}),
        fn = fullUrl and function() hs.urlevent.openURL(fullUrl) end or nil,
        disabled = fullUrl == nil,
      })
    end
  end
  table.insert(entries, {title="-"})
  table.insert(entries, {title="Open Google Cloud Status",
    fn=function() hs.urlevent.openURL("https://status.cloud.google.com") end})
  table.insert(entries, {title="Open Google Workspace Status",
    fn=function() hs.urlevent.openURL("https://www.google.com/appsstatus") end})
  return entries
end

local function buildModelSubmenu(dim, lc)
  local entries = {}
  local models = modelsData or {}
  if #models == 0 then
    for _, m in ipairs(KNOWN_GEMINI_MODELS) do table.insert(models, m) end
    for _, m in ipairs(KNOWN_3P_MODELS) do table.insert(models, m) end
  end

  local lastFam = nil
  for _, m in ipairs(models) do
    if lastFam and m.family ~= lastFam then table.insert(entries, {title="-"}) end
    lastFam = m.family
    local glyph = m.available and "✓" or "·"
    local txt = hs.styledtext.new(string.format("  %s  %s", glyph, m.name),
      {color = m.available and lc or dim})
    table.insert(entries, {title=txt, disabled=true})
  end
  table.insert(entries, {title="-"})
  table.insert(entries, {title="Open Gemini Model Documentation",
    fn=function() hs.urlevent.openURL(MODEL_DOCS_URL) end})
  return entries
end

local function buildMenu()
  local lc   = labelColor()
  local dim  = lc.white > 0.5 and {white=0.55, alpha=0.85} or {white=0.45, alpha=0.85}
  local bold = ".AppleSystemUIFontBold"
  local tabPS = {tabStops={{location=90, alignment="left"}}}

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
      {font={name=bold, size=13}, color=GEMINI_SESSION_CLR})
  end
  add(header, {disabled=true})
  sep()

  if fetchError then
    add(hs.styledtext.new("⚠  " .. fetchError, {color=WARN_RED}), {disabled=true})
    sep()
  end

  local d = lastData or {}

  -- Helper to render a quota section
  local function renderQuotaBlock(sectionTitle, clr, q5h, qWk)
    add(hs.styledtext.new(sectionTitle, {font={name=bold, size=10}, color=clr}), {disabled=true})

    -- 5-Hour Session
    if q5h then
      local rVal = getQuotaResetVal(q5h)
      local p = getQuotaPct(q5h, rVal)
      local tp = timeRemainingPct(rVal, 18000)
      add(hs.styledtext.new("  Session 5h\t", {color=lc, paragraphStyle=tabPS})
        .. styledBlockBar(p, clr, 14)
        .. hs.styledtext.new(string.format("  %d%% used", math.floor(p)), {color=lc}), {disabled=true})
      add(hs.styledtext.new("  Time left\t", {color=dim, paragraphStyle=tabPS})
        .. styledBlockBarFlat(tp, SAGE_CLR, 14)
        .. hs.styledtext.new(string.format("  %s", formatCountdown(rVal)), {color=dim}), {disabled=true})
      add(hs.styledtext.new(string.format("  Resets %s", formatReset(rVal)), {color=dim}), {disabled=true})
    else
      add(hs.styledtext.new("  Session 5h: No quota data yet (run 'agy' to sync)", {color=dim}), {disabled=true})
    end

    -- Weekly Window
    if qWk then
      local wVal = getQuotaResetVal(qWk)
      local wp = getQuotaPct(qWk, wVal)
      local wtp = timeRemainingPct(wVal, 604800)
      add(hs.styledtext.new("  Weekly 7d\t", {color=lc, paragraphStyle=tabPS})
        .. styledBlockBar(wp, clr, 14)
        .. hs.styledtext.new(string.format("  %d%% used", math.floor(wp)), {color=lc}), {disabled=true})
      add(hs.styledtext.new("  Time left\t", {color=dim, paragraphStyle=tabPS})
        .. styledBlockBarFlat(wtp, SAGE_CLR, 14)
        .. hs.styledtext.new(string.format("  %s", formatCountdown(wVal)), {color=dim}), {disabled=true})
      add(hs.styledtext.new(string.format("  Resets %s", formatReset(wVal)), {color=dim}), {disabled=true})
    else
      add(hs.styledtext.new("  Weekly 7d: No quota data yet (run 'agy' to sync)", {color=dim}), {disabled=true})
    end
  end

  local g5h = d.quota and d.quota["gemini-5h"] or d["gemini-5h"]
  local gWk = d.quota and d.quota["gemini-weekly"] or d["gemini-weekly"]
  local p5h = d.quota and d.quota["3p-5h"] or d["3p-5h"]
  local pWk = d.quota and d.quota["3p-weekly"] or d["3p-weekly"]

  -- Section 1: Gemini Models Quota
  renderQuotaBlock("GEMINI MODELS QUOTA", GEMINI_SESSION_CLR, g5h, gWk)
  sep()

  -- Section 2: Claude & 3P Partner Quota
  renderQuotaBlock("CLAUDE & 3P PARTNER QUOTA", CLAUDE_SESSION_CLR, p5h, pWk)

  -- ── Session & Context Metrics ───────────────────────────────────────
  if d.context_window or d.cost or d.model then
    sep()
    add(hs.styledtext.new("SESSION CONTEXT & TOKENS", {font={name=bold, size=10}, color=ROUTINE_CLR}), {disabled=true})
    if d.model and d.model.display_name then
      local effortStr = d.effort and (" (" .. d.effort .. ")") or ""
      add(hs.styledtext.new(string.format("  Model: %s%s", d.model.display_name, effortStr), {color=lc}), {disabled=true})
    end
    if d.context_window and d.context_window.used_percentage then
      local cp = math.max(0, math.min(100, d.context_window.used_percentage))
      local cSize = d.context_window.context_window_size or 1000000
      local cSizeStr = (cSize >= 1000000) and string.format("%dM", math.floor(cSize / 1000000)) or string.format("%dk", math.floor(cSize / 1000))
      add(hs.styledtext.new("  Context\t", {color=lc, paragraphStyle=tabPS})
        .. styledBlockBar(cp, ROUTINE_CLR, 14)
        .. hs.styledtext.new(string.format("  %d%% of %s", math.floor(cp), cSizeStr), {color=lc}), {disabled=true})
    end
    if d.context_window and (d.context_window.total_input_tokens or d.context_window.total_output_tokens) then
      local inTok  = d.context_window.total_input_tokens or 0
      local outTok = d.context_window.total_output_tokens or 0
      add(hs.styledtext.new(string.format("  Tokens: ▲ %d in  ·  ▼ %d out", inTok, outTok), {color=dim}), {disabled=true})
    end
    if d.cost and (d.cost.total_usd or d.cost.total_cost_usd) then
      local usd = d.cost.total_usd or d.cost.total_cost_usd or 0
      add(hs.styledtext.new(string.format("  Session Cost: $%.2f USD", usd), {color=dim}), {disabled=true})
    end
  end

  -- ── Service Health ──────────────────────────────────────────────────
  sep()
  local statusHeader = hs.styledtext.new("SERVICE STATUS", {font={name=bold, size=10}, color=lc})
  local dotClr = serviceHealthDotColor()
  if dotClr == SAGE_CLR then
    statusHeader = statusHeader .. hs.styledtext.new("  All Systems Operational", {font={name=bold, size=10}, color=SAGE_CLR})
  elseif dotClr == WARN_RED then
    statusHeader = statusHeader .. hs.styledtext.new("  Service Outage Detected", {font={name=bold, size=10}, color=WARN_RED})
  elseif dotClr == AMBER then
    statusHeader = statusHeader .. hs.styledtext.new("  Degraded Performance", {font={name=bold, size=10}, color=AMBER})
  end
  add(statusHeader, {disabled=true})

  add(hs.styledtext.new("  Google Cloud & Vertex AI", {color=lc}),
    {menu=buildIncidentSubmenu(dim)})

  -- ── Models ──────────────────────────────────────────────────────────
  sep()
  add(hs.styledtext.new("MODEL ROSTER", {font={name=bold, size=10}, color=lc}), {disabled=true})
  add(hs.styledtext.new("  All Available Models", {color=lc}),
    {menu=buildModelSubmenu(dim, lc)})

  -- ── Footer ──────────────────────────────────────────────────────────
  sep()
  if lastFetchTime then
    add(hs.styledtext.new("Updated " .. humanDuration(os.time() - lastFetchTime) .. " ago", {color=dim}), {disabled=true})
  end

  local waitSecs = math.ceil(backoffUntil - os.time())
  if waitSecs > 0 then
    add(hs.styledtext.new((BACKOFF_LABEL[backoffReason] or "Backing off") .. " — retry in " .. humanDuration(waitSecs), {color=dim}), {disabled=true})
  elseif isFetching then
    add(hs.styledtext.new("Fetching…", {color=dim}), {disabled=true})
  else
    add("Refresh now", {fn=function()
      obj:fetch()
      fetchPlan()
      fetchStatus()
      fetchIncidents()
      fetchModels()
    end})
  end

  return items
end

-- ── Network Fetching ───────────────────────────────────────────────────

function fetchPlan()
  if obj.planName and obj.planName ~= "" then
    planName = obj.planName
    return
  end
  local token, src = resolveAuthToken()
  if not (token and (src == "keychain" or src == "file")) then return end

  local body = hs.json.encode({mode = 1}) or "{}"
  hs.http.asyncPost(CODE_ASSIST_URL, body, {
    ["Authorization"] = "Bearer " .. token,
    ["Content-Type"]  = "application/json",
    ["User-Agent"]    = "Antigravity/1.0",
  }, function(status, respBody, _)
    if status == 200 then
      local ok, parsed = pcall(hs.json.decode, respBody)
      if ok and type(parsed) == "table" then
        local resolved = extractPlanName(parsed, obj.planName)
        if resolved and resolved ~= planName then
          planName = resolved
          refreshIcon()
        end
      end
    end
  end)
end

function fetchStatus()
  statusAttemptTime = os.time()
  hs.http.asyncGet(GCLOUD_SERVICES_URL, {}, function(status, body, _)
    if status ~= 200 then
      statusError = string.format("Google status unavailable (HTTP %d)", status)
      return
    end
    local ok, parsed = pcall(hs.json.decode, body)
    if ok and type(parsed) == "table" then
      statusData = parsed
      statusFetchTime = os.time()
      statusError = nil
      refreshIcon()
    end
  end)
end

function fetchIncidents()
  incidentsAttemptTime = os.time()
  hs.http.asyncGet(GCLOUD_STATUS_URL, {}, function(status, body, _)
    if status == 200 then
      local ok, parsed = pcall(hs.json.decode, body)
      if ok and type(parsed) == "table" then
        incidentsData = parsed
        incidentsError = nil
        refreshIcon()
      end
    else
      -- Fallback to Workspace status
      hs.http.asyncGet(WORKSPACE_STATUS_URL, {}, function(st2, body2, _)
        if st2 == 200 then
          local ok2, parsed2 = pcall(hs.json.decode, body2)
          if ok2 and type(parsed2) == "table" then
            incidentsData = parsed2
            incidentsError = nil
            refreshIcon()
          end
        end
      end)
    end
  end)
end

function fetchModels()
  if os.time() < backoffUntil then return end
  modelsAttemptTime = os.time()
  local discovered = discoverLocalModels()
  if discovered then
    modelsData = discovered
    modelsFetchTime = os.time()
    modelsError = nil
    return
  end

  -- Intersect known catalogs
  local list = {}
  for _, m in ipairs(KNOWN_GEMINI_MODELS) do
    table.insert(list, {id=m.id, name=m.name, family=m.family, available=true})
  end
  for _, m in ipairs(KNOWN_3P_MODELS) do
    table.insert(list, {id=m.id, name=m.name, family=m.family, available=true})
  end
  modelsData = list
  modelsFetchTime = os.time()
end

--- GeminiUsage:fetch()
--- Method
--- Immediately fetches current quota and usage data.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The GeminiUsage object
---
--- Notes:
---  * Called automatically on start and by the poll timer. Updates the menu bar icon and dropdown menu.
function obj:fetch()
  if isFetching then return self end
  if os.time() < backoffUntil then return self end
  isFetching = true

  -- 1. Try reading live statusline quota cache
  local cached = loadCachedQuota()
  if cached then
    lastData = cached
    lastFetchTime = os.time()
    fetchError = nil
    planName = obj.planName or extractPlanName(cached, obj.planName) or planName
    clearBackoff()
    refreshIcon()
    isFetching = false
    if not planName or planName == "Antigravity" then
      fetchPlan()
    end
    return self
  end

  -- 2. Query Google Cloud Code Assist endpoint if token is present
  local token, src = resolveAuthToken()
  if token and (src == "keychain" or src == "file") then
    local body = hs.json.encode({mode = 1}) or "{}"
    hs.http.asyncPost(CODE_ASSIST_URL, body, {
      ["Authorization"] = "Bearer " .. token,
      ["Content-Type"]  = "application/json",
      ["User-Agent"]    = "Antigravity/1.0",
    }, function(status, respBody, headers)
      isFetching = false
      if status == 200 then
        local ok, parsed = pcall(hs.json.decode, respBody)
        if ok and type(parsed) == "table" then
          planName = obj.planName or extractPlanName(parsed, obj.planName) or planName or "Antigravity"
          if not lastData then
            lastData = {
              plan = planName,
              product = "antigravity",
            }
          end
          lastFetchTime = os.time()
          fetchError = nil
          clearBackoff()
          refreshIcon()
          return
        end
      elseif status == 429 then
        local _ra = tonumber(headers and (headers["Retry-After"] or headers["retry-after"]))
        local secs = enterBackoff("ratelimit", _ra)
        print(string.format("[GeminiUsage] HTTP 429 rate limited, retry in %ds", secs))
      elseif status == 401 then
        fetchError = "Token expired — run 'agy' to re-authenticate"
      else
        local isNetwork = (status == nil) or (status < 0)
        local secs = enterBackoff(isNetwork and "network" or "server")
        fetchError = isNetwork and "Connection failed" or string.format("HTTP %d error", status)
      end
      refreshIcon()
    end)
    return self
  end

  -- 3. Fallback when credentials are not yet initialized
  isFetching = false
  if not lastData then
    fetchError = "No active agy session or token found"
  end
  refreshIcon()
  return self
end

-- ── Lifecycle Methods ──────────────────────────────────────────────────

--- GeminiUsage:init()
--- Method
--- Prepares the menu bar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The GeminiUsage object
---
--- Notes:
---  * Called automatically by hs.loadSpoon(); do not call manually. Does not start background polling or make network requests.
function obj:init()
  if menubar then menubar:delete(); menubar = nil end

  menubar = hs.menubar.new()
  menubar:setTitle("…")
  menubar:setMenu(buildMenu)

  return self
end

--- GeminiUsage:start()
--- Method
--- Starts background polling.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The GeminiUsage object
---
--- Notes:
---  * Performs an immediate fetch then schedules subsequent fetches every GeminiUsage.pollInterval seconds.
function obj:start()
  if timer then timer:stop(); timer = nil end
  self:init()
  self:fetch()
  fetchPlan()
  fetchStatus()
  fetchIncidents()
  fetchModels()

  timer = hs.timer.new(obj.pollInterval, function()
    self:fetch()
    if not planName or planName == "Antigravity" then
      fetchPlan()
    end
    local now = os.time()
    if now - (statusAttemptTime or 0) >= obj.statusPollInterval then
      fetchStatus()
    end
    if now - (incidentsAttemptTime or 0) >= obj.incidentsPollInterval then
      fetchIncidents()
    end
    if now - (modelsAttemptTime or 0) >= obj.modelsPollInterval then
      fetchModels()
    end
  end)
  timer:start()
  return self
end

--- GeminiUsage:stop()
--- Method
--- Stops background polling and removes the menu bar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The GeminiUsage object
function obj:stop()
  if timer      then timer:stop();      timer      = nil end
  if resetTimer then resetTimer:stop(); resetTimer = nil end
  if menubar    then menubar:delete();  menubar    = nil end

  lastData, lastFetchTime, fetchError, planName = nil, nil, nil, nil
  statusData, statusFetchTime, statusError, statusAttemptTime = nil, nil, nil, nil
  incidentsData, incidentsError, incidentsAttemptTime = nil, nil, nil
  modelsData, modelsFetchTime, modelsError, modelsAttemptTime = nil, nil, nil, nil
  isFetching = false
  clearBackoff()
  return self
end

return obj
