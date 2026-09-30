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
--- A model roster sits alongside it, built by intersecting the /v1/models list
--- for the signed-in account with the model catalog baked into the local
--- `claude` binary. See modelRows for what the three resulting states mean.
---
--- Credentials come from the macOS Keychain entry "Claude Code-credentials"
--- (set by Claude Code). That entry is authoritative when it exists: the spoon
--- neither reads nor writes ~/.claude/.credentials.json in that case. The file
--- is used only by installs that have no Keychain entry at all. The status
--- endpoints are public and need no authentication.

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

--- ClaudeUsage.modelsPollInterval
--- Variable
--- Minimum seconds between api.anthropic.com model list fetches. Default 3600.
--- The roster only changes when Anthropic launches or retires a model, or when
--- the account's plan changes, so it is polled far less often than anything else.
obj.modelsPollInterval = 3600

--- ClaudeUsage.claudeBinPaths
--- Variable
--- Extra locations to search for the `claude` binary, tried in order before the
--- PATH lookup, so an entry here overrides whatever PATH would have found. Each
--- entry is an absolute path to the binary or to a symlink pointing at it.
--- Entries that do not exist are skipped with a console note, so one list can
--- cover several machines. Accepts a string or a table of strings. Default {}.
---
--- Full search order: these entries, then /opt/homebrew/bin, /usr/local/bin
--- and ~/.local/bin, then `command -v claude` in your login shell.
---
--- Only needed when `claude` is installed somewhere the spoon cannot find on its
--- own; the binary supplies the client_id, version and anthropic-beta headers,
--- and the spoon falls back to pinned values when it cannot be read.
---
--- Resolved once and cached on first use, so set this before ClaudeUsage:start().
--- To change it later, call ClaudeUsage:stop() then ClaudeUsage:start(), or
--- reload Hammerspoon.
---
--- Example:
---   spoon.ClaudeUsage.claudeBinPaths = {"/opt/custom/bin/claude"}
obj.claudeBinPaths = {}

--- ClaudeUsage.autoRefreshToken
--- Variable
--- When true, the spoon will attempt to refresh an expired OAuth token itself
--- and write the result back to ~/.claude/.credentials.json. Disabled by default:
--- Claude Code owns the token lifecycle and will refresh it on its next run.
--- Enable only if the spoon is running without Claude Code active.
---
--- Has no effect when the credentials came from the Keychain — see resolveToken.
obj.autoRefreshToken = false

local menubar, timer
local lastData, lastFetchTime, fetchError, planName
local statusData, statusFetchTime, statusError, statusAttemptTime
local incidentsData, incidentsError, incidentsAttemptTime
local modelsData, modelsFetchTime, modelsError, modelsAttemptTime
local tsCache     = {}
local isFetching       = false

-- ── Backoff ────────────────────────────────────────────────────────────
-- Every transient failure against api.anthropic.com shares one ladder, because
-- they share one cause: the host does not want to hear from us right now. A
-- 429, a connection timeout and a 5xx all mean wait longer before asking again.
--
-- Honouring Retry-After alone is not enough. The server advises ~4 minutes and
-- keeps advising it, so a client that only ever waits that long resumes full
-- rate polling and is throttled again a few polls later — a sawtooth that never
-- settles. Taking the larger of the server's floor and our own escalation keeps
-- the advice authoritative while still converging when it proves insufficient.
local backoffUntil    = 0
local backoffFailures = 0
local backoffReason   = nil

local BACKOFF_CAP   = 3600
local BACKOFF_LABEL = {
  ratelimit = "Rate limited",
  network   = "Connection failed",
  server    = "Server error",
}

-- Doubles each strike up to an hour, so the first failure costs no more than an
-- ordinary poll and a lone blip is not punished, while a persistent one settles
-- at hourly.
--
-- floor is a server-supplied Retry-After, and it sets the scale to escalate
-- from rather than merely a one-off minimum. Escalating from pollInterval
-- instead would spend the first two strikes below the server's own advice —
-- against the logged storm, where the host kept advising ~250s and ~250s kept
-- proving too short, doubling its figure converges in one strike where doubling
-- ours takes three.
--
-- Jitter keeps the spoon from lining up with Claude Code, which polls the same
-- endpoint on its own schedule, and is applied before the floor so a downward
-- nudge can never take us under what the server asked for. math.random is left
-- unseeded — Lua seeds it per process, and seeding here would reach into every
-- other spoon sharing this Lua state.
local function backoffSeconds(failures, floor)
  local growth   = 2 ^ math.max(0, failures - 1)
  local nominal  = math.max(obj.pollInterval, floor or 0) * growth
  local jittered = math.floor(math.min(nominal, BACKOFF_CAP) * (0.9 + math.random() * 0.2))
  return math.min(math.max(jittered, floor or 0), BACKOFF_CAP)
end

-- Returns the seconds waited, for logging.
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

-- Assigned in the Fetch section; declared here so buildMenu can close over them.
local fetchStatus, fetchIncidents, fetchModels

local CREDS_PATH    = os.getenv("HOME") .. "/.claude/.credentials.json"
local USAGE_URL     = "https://api.anthropic.com/api/oauth/usage"
local TOKEN_URL     = "https://platform.claude.com/v1/oauth/token"
local STATUS_URL    = "https://status.claude.com/api/v2/summary.json"
local INCIDENTS_URL = "https://status.claude.com/api/v2/incidents.json"
local MODELS_URL    = "https://api.anthropic.com/v1/models?limit=100"

-- Printed in the binary's own "not available for your account" copy, so it is
-- the page Claude Code itself points at for model availability questions.
local MODEL_DOCS_URL = "https://code.claude.com/docs/en/model-config"

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
local _cachedCatalog   = nil
local _discoveryTask   = nil
local _isDiscovering   = false

local DEFAULT_CLIENT_ID  = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  -- extracted from v2.1.158
local DEFAULT_USER_AGENT = "claude-code/2.1.158"
local DEFAULT_OAUTH_BETA = "oauth-2025-04-20"                      -- extracted from v2.1.158

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Searched after the configured paths, so the spoon finds claude via standard
-- locations immediately without spawning an interactive shell.
local DEFAULT_BIN_PATHS = {
  "/opt/homebrew/bin/claude",
  "/usr/local/bin/claude",
  os.getenv("HOME") .. "/.local/bin/claude",
}

-- A symlink may point at another symlink (Homebrew's bin shim → a Caskroom
-- version directory), so follow the chain rather than a single hop. Uses
-- in-process symlinkAttributes when available to avoid spawning subshells.
local function resolveSymlinks(path)
  for _ = 1, 10 do
    local target = nil
    if hs.fs and hs.fs.symlinkAttributes then
      target = hs.fs.symlinkAttributes(path, "target")
      if not target then return path end
    else
      local ok, res = pcall(hs.execute, "readlink " .. shellQuote(path) .. " 2>/dev/null")
      target = ok and type(res) == "string" and res:gsub("%s+$", "") or ""
      if target == "" then return path end
    end
    if target:sub(1,1) ~= "/" then target = (path:match("(.*/)") or "") .. target end
    path = target
  end
  return path
end

local function fileExists(path)
  return path ~= "" and hs.fs.attributes(path, "mode") ~= nil
end

-- ClaudeUsage.claudeBinPaths accepts a bare string as a convenience, so normalise
-- to a list before searching.
local function configuredBinPaths()
  local configured = obj.claudeBinPaths
  if type(configured) == "string" then return {configured} end
  if type(configured) ~= "table"  then return {} end
  return configured
end

-- Hammerspoon is launched by Finder with a minimal PATH, so finding claude means
-- asking the user's shell — hs.execute's second argument runs the command in a
-- login interactive shell. Used only as a fallback when neither configured
-- nor default locations contain the binary.
local LOOKUP_MARKER = "__CLAUDEUSAGE_BIN__"
local LOOKUP_CMD =
  [[printf '__CLAUDEUSAGE_BIN__%s__CLAUDEUSAGE_BIN__' "$(command -v claude 2>/dev/null)"]]

local function shellLookupClaude()
  local ok, out = pcall(hs.execute, LOOKUP_CMD, true)
  if not ok or type(out) ~= "string" then return nil end
  local path = out:match(LOOKUP_MARKER .. "(.-)" .. LOOKUP_MARKER)
  if not path then return nil end
  path = path:gsub("^%s+", ""):gsub("%s+$", "")
  if path:sub(1,1) ~= "/" then return nil end
  return path
end

-- claude is installed several different ways — a Homebrew cask, the official
-- installer's ~/.local/bin shim, npm — so candidates are gathered in preference
-- order. Configured paths lead, followed by standard locations, and finally
-- shell lookup if needed.
local function claudeBinPath()
  if _cachedBinPath then return _cachedBinPath end
  for _, path in ipairs(configuredBinPaths()) do
    if type(path) == "string" and fileExists(path) then
      _cachedBinPath = resolveSymlinks(path)
      return _cachedBinPath
    end
    print("[ClaudeUsage] claudeBinPaths entry not found, skipping: " .. tostring(path))
  end

  for _, path in ipairs(DEFAULT_BIN_PATHS) do
    if fileExists(path) then
      _cachedBinPath = resolveSymlinks(path)
      return _cachedBinPath
    end
  end

  local fromShell = shellLookupClaude()
  if fromShell and fileExists(fromShell) then
    _cachedBinPath = resolveSymlinks(fromShell)
    return _cachedBinPath
  end

  print("[ClaudeUsage] WARNING: claude binary not found on PATH or in the default " ..
        "locations — set ClaudeUsage.claudeBinPaths to its location")
  _cachedBinPath = DEFAULT_BIN_PATHS[#DEFAULT_BIN_PATHS]
  return _cachedBinPath
end

-- Asynchronous background metadata extraction: reads client_id, version,
-- anthropic-beta, and model catalog in a background hs.task so the main thread
-- never freezes scanning a 100MB binary.
local function parseCatalogOutput(out)
  local catalog = {byFirstParty = {}, order = {}}
  for line in tostring(out):gmatch("[^\n]+") do
    local id, displayName, firstParty =
      line:match('id:"([^"]+)",family:"[^"]+",display_name:"([^"]+)".-first_party:"([^"]+)"')
    if id then
      local entry = {id=id, displayName=displayName, firstParty=firstParty}
      catalog.byFirstParty[firstParty] = entry
      table.insert(catalog.order, entry)
    end
  end
  return catalog
end

local function startBackgroundDiscovery()
  if _isDiscovering or _cachedCatalog then return end
  local bin = claudeBinPath()
  if not fileExists(bin) then return end
  if not (hs.task and hs.task.new) then return end
  _isDiscovering = true

  local script = string.format([[
BIN=%s
"$BIN" --version 2>/dev/null
echo "===CLAUDE_SPLIT==="
STRINGS=$(strings -n 6 "$BIN" 2>/dev/null)
echo "$STRINGS" | grep -oE 'CLIENT_ID:"[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}' | head -1
echo "===CLAUDE_SPLIT==="
echo "$STRINGS" | grep -oE 'oauth-[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1
echo "===CLAUDE_SPLIT==="
echo "$STRINGS" | grep -oE 'id:"claude-[a-z0-9.-]+",family:"[a-z]+",display_name:"[^"]+"[^}]*provider_ids:\{first_party:"[^"]+"'
]], shellQuote(bin))

  _discoveryTask = hs.task.new("/bin/sh", function(exitCode, stdOut, _)
    _isDiscovering = false
    _discoveryTask = nil
    if exitCode ~= 0 or not stdOut or stdOut == "" then return end

    local parts = {}
    local pattern = "===CLAUDE_SPLIT===\n?"
    local lastEnd = 1
    local sStart, sEnd = stdOut:find(pattern, 1)
    while sStart do
      table.insert(parts, stdOut:sub(lastEnd, sStart - 1))
      lastEnd = sEnd + 1
      sStart, sEnd = stdOut:find(pattern, lastEnd)
    end
    table.insert(parts, stdOut:sub(lastEnd))

    local ver = parts[1] and parts[1]:gsub("%s+$", "") or ""
    local v   = ver:match("^([0-9]+%.[0-9]+%.[0-9]+)")
    if v then _cachedUserAgent = "claude-code/" .. v end

    local cid = parts[2] and parts[2]:gsub("%s+$", "") or ""
    if cid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      _cachedClientId = cid
    end

    local ob = parts[3] and parts[3]:gsub("%s+$", "") or ""
    if ob ~= "" and ob:match("^oauth%-[0-9]") then
      _cachedOauthBeta = ob
    end

    local catStr = parts[4] or ""
    local cat = parseCatalogOutput(catStr)
    if #cat.order > 0 then
      _cachedCatalog = cat
    end
  end, {"-c", script})

  if _discoveryTask then
    _discoveryTask:start()
  end
end

local function getClientId()
  if _cachedClientId then return _cachedClientId end
  startBackgroundDiscovery()
  return DEFAULT_CLIENT_ID
end

local function getUserAgent()
  if _cachedUserAgent then return _cachedUserAgent end
  startBackgroundDiscovery()
  return DEFAULT_USER_AGENT
end

local function getOauthBeta()
  if _cachedOauthBeta then return _cachedOauthBeta end
  startBackgroundDiscovery()
  return DEFAULT_OAUTH_BETA
end

local function claudeModelCatalog()
  if _cachedCatalog then return _cachedCatalog end
  startBackgroundDiscovery()
  return {byFirstParty = {}, order = {}}
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

-- ── Claude models ──────────────────────────────────────────────────────
-- Availability has two independent halves, and the /model picker shows them
-- through the same greyed-out row. Separating them matters because the fix
-- differs: one is a plan or account limit, the other is a stale local install.

local MODEL_STATE = {
  available   = {glyph="✓", color=SAGE_CLR},
  needsUpdate = {glyph="▲", color=AMBER, label="update Claude Code to use"},
  unavailable = {glyph="·",              label="not available to your account"},
}

-- Rendering order, which is also the order the submenu groups its separators by.
local MODEL_STATE_ORDER = {"available", "needsUpdate", "unavailable"}

-- The catalog says "Opus 5" where the API says "Claude Opus 5".
local function stripClaudePrefix(name)
  return (tostring(name):gsub("^Claude%s+", ""))
end

-- /v1/models is what the account may call; the binary catalog is what this
-- build can select. Intersecting them yields the three states above:
--   in both                → available
--   API only               → the account has it but this build predates it
--   catalog only           → this build knows it but the account cannot call it
--
-- Requires modelsData; callers render the fetching or error state instead when
-- it is nil. An unreadable catalog degrades to listing every model as available
-- rather than inventing a roster the account has supposedly lost.
local function modelRows()
  local catalog     = claudeModelCatalog()
  local haveCatalog = #catalog.order > 0
  local grouped     = {available={}, needsUpdate={}, unavailable={}}
  local seen        = {}

  for _, model in ipairs(modelsData) do
    local entry = catalog.byFirstParty[model.id]
    if entry then seen[entry.id] = true end
    local state = (entry or not haveCatalog) and "available" or "needsUpdate"
    table.insert(grouped[state], {
      state = state,
      name  = entry and entry.displayName
                     or stripClaudePrefix(model.display_name or model.id),
    })
  end

  if haveCatalog then
    for _, entry in ipairs(catalog.order) do
      if not seen[entry.id] then
        table.insert(grouped.unavailable, {state="unavailable", name=entry.displayName})
      end
    end
  end

  local rows, counts = {}, {}
  for _, state in ipairs(MODEL_STATE_ORDER) do
    counts[state] = #grouped[state]
    for _, row in ipairs(grouped[state]) do table.insert(rows, row) end
  end
  return rows, counts
end

-- ── Auth ───────────────────────────────────────────────────────────────

-- Returns (accessToken, planDisplay, error, refreshToken).
-- refreshToken is returned even on "expired" so callers can attempt a refresh.
--
-- Both stores hold more than the Claude.ai session: Claude Code keeps per-server
-- MCP OAuth under mcpOAuth in the same blob, and that section is serialised
-- first. Pattern-matching the flat text would therefore return whichever
-- accessToken appears earliest — an MCP server's token, which the usage endpoint
-- rejects with "Invalid bearer token", carrying an unrelated expiresAt that lets
-- it sail past the expiry check. Decode and read claudeAiOauth by name.
local function parseCredentials(raw)
  if not raw or raw:match("^%s*$") then return nil, nil, "empty", nil end
  local ok, creds = pcall(hs.json.decode, raw)
  if not (ok and type(creds) == "table") then return nil, nil, "unparsable", nil end
  local oauth = creds.claudeAiOauth
  if type(oauth) ~= "table" then return nil, nil, "no_token", nil end
  local token   = type(oauth.accessToken)  == "string" and oauth.accessToken  or nil
  local refresh = type(oauth.refreshToken) == "string" and oauth.refreshToken or nil
  local plan    = type(oauth.subscriptionType) == "string" and oauth.subscriptionType or nil
  local expMs   = tonumber(oauth.expiresAt)
  if not token or token == "" then return nil, nil, "no_token", refresh end
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

-- Returns (accessToken, planDisplay, error, refreshToken, source), where source
-- is "keychain" or "file".
--
-- The Keychain entry belongs to Claude Code and is authoritative whenever it
-- exists — expired or malformed included. The file is not even opened in that
-- case, so the two stores can never disagree.
--
-- Treating them as interchangeable is what causes damage: a refresh rotates the
-- refresh token server-side, so refreshing a Keychain-sourced token and
-- persisting the result to the file would leave Claude Code reading a Keychain
-- entry whose refresh token the server has already invalidated. Its next
-- refresh fails with invalid_grant and the user is logged out of Claude Code by
-- a menu bar widget. Writing the file also creates a plaintext copy of an OAuth
-- token for a user who had chosen to keep it in the Keychain.
local _cachedTokenData = nil
local _cachedTokenTime = 0
local TOKEN_CACHE_TTL  = 60  -- 60s memory cache to prevent repeated Keychain forks

local function resolveToken(forceFresh)
  local now = os.time()
  if not forceFresh and _cachedTokenData and (now - _cachedTokenTime < TOKEN_CACHE_TTL) then
    local unpackFn = table.unpack or unpack
    local token, pd, err, rt, source = unpackFn(_cachedTokenData)
    if token and not err then
      return token, pd, err, rt, source
    end
  end

  local token, pd, err, rt = getClaudeKeychain()
  local source = "keychain"
  if err == "empty" then
    token, pd, err, rt = loadCredentials()
    source = "file"
  end

  _cachedTokenData = {token, pd, err, rt, source}
  _cachedTokenTime = now
  return token, pd, err, rt, source
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
  local key = (font.name or "") .. "|" .. text
  if titleFitCache[key] then return titleFitCache[key] end

  -- Fast path: short strings will always fit in INCIDENT_TITLE_WIDTH (320pt) at 13pt
  if #text <= 35 then
    titleFitCache[key] = text
    return text
  end

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
    -- Binary search for the cutoff point: O(log N) measurements instead of linear stepping
    local low, high = 1, #text
    local best = 1
    while low <= high do
      local mid = math.floor((low + high) / 2)
      local cand = trimToCharBoundary(text:sub(1, mid))
      if widthOf(cand .. "…") <= INCIDENT_TITLE_WIDTH then
        best = #cand
        low = mid + 1
      else
        high = mid - 1
      end
    end
    fitted = trimToCharBoundary(text:sub(1, best)):gsub("%s+$", "") .. "…"
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
  for i, incident in ipairs(incidentsData) do
    if i > 12 then break end
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

-- Mirrors the component rows in the status section: the third column is filled
-- only when something needs saying, so a healthy roster stays two columns wide.
local function modelRowText(row, ps, lc, dim)
  local state = MODEL_STATE[row.state]
  local color = state.color or dim
  local text = hs.styledtext.new("  " .. state.glyph, {color=color, paragraphStyle=ps})
    .. hs.styledtext.new("\t" .. row.name,
         {color = row.state == "unavailable" and dim or lc, paragraphStyle=ps})
  if state.label then
    text = text .. hs.styledtext.new("\t" .. state.label, {color=color, paragraphStyle=ps})
  end
  return text
end

local function buildModelSubmenu(rows, ps, lc, dim)
  local entries, lastState = {}, nil
  for _, row in ipairs(rows) do
    if lastState and row.state ~= lastState then table.insert(entries, {title="-"}) end
    lastState = row.state
    table.insert(entries, {title=modelRowText(row, ps, lc, dim), disabled=true})
  end
  table.insert(entries, {title="-"})
  table.insert(entries, {title="Open model docs",
    fn=function() hs.urlevent.openURL(MODEL_DOCS_URL) end})
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

  -- ── Models ──────────────────────────────────────────────────────────
  -- The full roster lives in a submenu because it runs to a dozen-odd rows, but
  -- anything needing action is lifted into the dropdown itself: a model the
  -- account can already call and only a stale install is holding back.
  sep()
  local modelPS = {tabStops={{location=24,  alignment="left"},
                             {location=176, alignment="left"}}}
  add(hs.styledtext.new("MODELS", {font={name=bold, size=10}, color=lc}), {disabled=true})

  if modelsError then
    local lastOk = modelsFetchTime
      and (" · last ok " .. humanDuration(os.time() - modelsFetchTime) .. " ago") or ""
    add(hs.styledtext.new("  " .. modelsError .. lastOk, {color=dim}), {disabled=true})
  elseif not modelsData then
    add(hs.styledtext.new("  Fetching…", {color=dim}), {disabled=true})
  else
    local rows, counts = modelRows()
    for _, row in ipairs(rows) do
      if row.state == "needsUpdate" then
        add(modelRowText(row, modelPS, lc, dim), {disabled=true})
      end
    end
    local summary = {}
    if counts.available   > 0 then
      table.insert(summary, counts.available .. " available") end
    if counts.needsUpdate > 0 then
      table.insert(summary, counts.needsUpdate .. " need an update") end
    if counts.unavailable > 0 then
      table.insert(summary, counts.unavailable .. " unavailable") end
    add(hs.styledtext.new("  " .. table.concat(summary, " · "), {color=dim}),
        {disabled=true})
    add(hs.styledtext.new("  All models", {color=lc}),
        {menu=buildModelSubmenu(rows, modelPS, lc, dim)})
  end

  -- ── Footer ──────────────────────────────────────────────────────────
  sep()
  if lastFetchTime then
    add(hs.styledtext.new(
      "Updated " .. humanDuration(os.time() - lastFetchTime) .. " ago",
      {color=dim}), {disabled=true})
  end
  -- "Refresh now" is deliberately absent while backing off: the wait is the
  -- point, and a button that reopens the request would undo it.
  local waitSecs = math.ceil(backoffUntil - os.time())
  if waitSecs > 0 then
    add(hs.styledtext.new(
      (BACKOFF_LABEL[backoffReason] or "Backing off")
        .. " — retry in " .. humanDuration(waitSecs),
      {color=dim}), {disabled=true})
  elseif isFetching then
    add(hs.styledtext.new("Fetching…", {color=dim}), {disabled=true})
  else
    add("Refresh now", {fn=function()
      _cachedTokenData = nil
      obj:fetch()
      fetchStatus()
      fetchIncidents()
      fetchModels()
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
  -- The Keychain is never written, and resolveToken guarantees this function is
  -- only reached when the file was also the source: mirroring a refresh into
  -- Claude Code's Keychain entry would mean passing the token as a CLI argument
  -- to `security`, exposing it in `ps`.
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
            _cachedTokenData = nil
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
      -- Pre-calculate title fit in background callback so opening menu is instantaneous
      if type(incidentsData) == "table" then
        for i, inc in ipairs(incidentsData) do
          if i > 12 then break end
          local font = {name = inc.impact == "critical" and ".AppleSystemUIFontBold" or INCIDENT_FONT_NAME,
                        size = INCIDENT_FONT_SIZE}
          fitIncidentTitle(inc.name or "Untitled incident", font)
        end
      end
    end)
end

-- Shares the usage endpoint's OAuth token. Like the status fetches, a failure
-- here never sets fetchError or the ⚠ title: the roster is context, and losing
-- it says nothing about the plan usage the icon exists to report. An expired
-- token is left alone rather than triggering a refresh, since obj:fetch owns
-- that lifecycle and runs far more often.
function fetchModels()
  -- Shares a host with the usage endpoint, so it shares the backoff. Checked
  -- before modelsAttemptTime is stamped, so a roster skipped during a backoff is
  -- retried as soon as the window clears rather than an hour later.
  if os.time() < backoffUntil then return end
  modelsAttemptTime = os.time()
  local token = resolveToken()
  if not token then
    modelsError = "model list needs a valid token"
    return
  end
  hs.http.asyncGet(MODELS_URL, {
    ["Authorization"]     = "Bearer " .. token,
    ["anthropic-beta"]    = getOauthBeta(),
    ["anthropic-version"] = "2023-06-01",
    ["User-Agent"]        = getUserAgent(),
  }, function(status, body, headers)
    if not menubar then return end  -- stop() fired while request was in-flight
    -- Escalates the shared ladder but never clears it: a roster that loads says
    -- nothing about whether the usage endpoint is still being throttled, and
    -- only obj:fetch succeeding is evidence of that.
    if status == 429 then
      local _ra = tonumber(headers and (headers["Retry-After"] or headers["retry-after"]))
      local secs = enterBackoff("ratelimit", _ra)
      print(string.format("[ClaudeUsage] models fetch HTTP 429 (%d in a row), retry in %ds",
        backoffFailures, secs))
      modelsError = "model list rate limited"
      return
    end
    if status ~= 200 then
      print(string.format("[ClaudeUsage] models fetch HTTP %d: %s",
        status, tostring(body):sub(1, 200)))
      modelsError = string.format("model list unavailable (HTTP %d)", status)
      return
    end
    local ok, parsed = pcall(hs.json.decode, body)
    if not (ok and type(parsed) == "table" and type(parsed.data) == "table") then
      modelsError = "model list returned unexpected data"
      return
    end
    modelsData      = parsed.data
    modelsFetchTime = os.time()
    modelsError     = nil
  end)
end

--- ClaudeUsage:fetch()
--- Method
--- Immediately fetches current usage from the Anthropic API and updates the menu bar.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
---
--- Notes:
---  * Called automatically on start and by the poll timer; can also be triggered manually via the "Refresh now" menu item.
function obj:fetch()
  if isFetching then return end
  if os.time() < backoffUntil then return end
  isFetching = true

  local token, pd, err, rt, source = resolveToken()
  if pd then planName = pd end

  if not token then
    print(string.format("[ClaudeUsage] no token from %s, err=%s", source, tostring(err)))
    if err == "expired" then
      -- Only file-sourced credentials may be refreshed: doTokenRefresh persists
      -- to the file, which is not where a Keychain-sourced token is read from.
      if obj.autoRefreshToken and rt and source == "file" then
        isFetching = false  -- must clear before handing off; doTokenRefresh calls fetch() on completion
        doTokenRefresh(rt)
        return
      end
      if obj.autoRefreshToken and source == "keychain" then
        print("[ClaudeUsage] not auto-refreshing: credentials are Keychain-owned")
      end
      fetchError = "Token expired — waiting for Claude Code to refresh"
    elseif err == "no_file" then
      fetchError = "Credentials not found: " .. CREDS_PATH
    else
      local store = (source == "keychain")
        and 'Keychain entry "Claude Code-credentials"' or CREDS_PATH
      fetchError = (err == "unparsable")
        and ("Could not parse " .. store)
        or  ("No claudeAiOauth token in " .. store)
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
        clearBackoff()
        refreshIcon()
      else
        fetchError = "Bad response from server"
        menubar:setIcon(); menubar:setTitle("⚠")
      end
    elseif status == 429 then
      local _ra = tonumber(headers and (headers["Retry-After"] or headers["retry-after"]))
      local secs = enterBackoff("ratelimit", _ra)
      print(string.format("[ClaudeUsage] HTTP 429 rate limited (%d in a row), retry in %ds",
        backoffFailures, secs))
      menubar:setIcon(); menubar:setTitle("⚠")
    elseif status == 401 then
      -- Deliberately outside the ladder: the fix is a token refresh, not a
      -- longer wait, and backing off here would delay recovery once Claude Code
      -- writes a fresh token.
      print("[ClaudeUsage] HTTP 401 auth error: " .. tostring(body):sub(1, 200))
      _cachedTokenData = nil
      fetchError = "Auth failed — re-open Claude Code to refresh token"
      menubar:setIcon(); menubar:setTitle("⚠")
    else
      -- hs.http reports a connection failure as -1, which is not a status code
      -- and must not be shown as one.
      local isNetwork = (status == nil) or (status < 0)
      local secs = enterBackoff(isNetwork and "network" or "server")
      print(string.format("[ClaudeUsage] %s (%d in a row), retry in %ds: %s",
        isNetwork and "connection failed" or ("HTTP " .. tostring(status) .. " error"),
        backoffFailures, secs, tostring(body):sub(1, 200)))
      fetchError = isNetwork
        and ("Connection failed — retrying in " .. humanDuration(secs))
        or  string.format("HTTP %d from usage endpoint", status)
      menubar:setIcon(); menubar:setTitle("⚠")
    end
  end)
end

-- ── Lifecycle ──────────────────────────────────────────────────────────

--- ClaudeUsage:init()
--- Method
--- Prepares the menu bar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
---
--- Notes:
---  * Called automatically by hs.loadSpoon(); do not call manually. Does not start background polling or make any network requests.
function obj:init()
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  menubar:setTitle("…")
  menubar:setMenu(buildMenu)
  return self
end

--- ClaudeUsage:start()
--- Method
--- Starts background polling.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClaudeUsage object
---
--- Notes:
---  * Performs an immediate fetch then schedules subsequent fetches every ClaudeUsage.pollInterval seconds.
function obj:start()
  if timer then timer:stop(); timer = nil end
  startBackgroundDiscovery()
  self:fetch()
  fetchStatus()
  fetchIncidents()
  fetchModels()
  timer = hs.timer.new(obj.pollInterval, function()
    self:fetch()
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
  if _discoveryTask then _discoveryTask:terminate(); _discoveryTask = nil end
  _isDiscovering   = false
  lastData, lastFetchTime, fetchError, planName = nil, nil, nil, nil
  statusData, statusFetchTime, statusError, statusAttemptTime = nil, nil, nil, nil
  incidentsData, incidentsError, incidentsAttemptTime = nil, nil, nil
  modelsData, modelsFetchTime, modelsError, modelsAttemptTime = nil, nil, nil, nil
  tsCache          = {}
  titleFitCache    = {}
  _cachedTokenData = nil
  _cachedTokenTime = 0
  isFetching       = false
  isRefreshing     = false
  clearBackoff()
  _cachedBinPath, _cachedClientId, _cachedUserAgent, _cachedOauthBeta = nil, nil, nil, nil
  _cachedCatalog   = nil
  return self
end

return obj
