-- Standalone Unit and Functional Test Suite for PasswordGenerator.spoon
-- Compatible with LuaJIT / Lua 5.1 / 5.2 / 5.3 / 5.4

local passed = 0
local failed = 0

local function assert_true(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. (msg or "assertion failed"))
    print(debug.traceback())
  end
end

local function assert_equal(expected, actual, msg)
  if expected == actual then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL: %s (expected '%s', got '%s')", msg or "not equal", tostring(expected), tostring(actual)))
  end
end

local function assert_match(pattern, str, msg)
  if str and tostring(str):match(pattern) then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL: %s (pattern '%s' not found in '%s')", msg or "no match", pattern, tostring(str)))
  end
end

-- Mock Hammerspoon runtime environment
local clipboardContent = nil
local lastKeyStrokes = nil
local lastAlert = nil
local timerCallbacks = {}
local lastBoundEventTap = nil

_G.hs = {
  settings = {
    _data = {},
    get = function(key) return _G.hs.settings._data[key] end,
    set = function(key, val) _G.hs.settings._data[key] = val end
  },
  pasteboard = {
    setContents = function(str) clipboardContent = str; return true end,
    getContents = function() return clipboardContent end,
    clearContents = function() clipboardContent = nil end,
    writeObjects = function(...) return true end
  },
  eventtap = {
    event = {
      types = {
        keyDown = 10,
        leftMouseDown = 1,
        rightMouseDown = 2
      }
    },
    new = function(types, fn)
      local tap = {
        callback = fn,
        _started = false,
        start = function(self) self._started = true end,
        stop = function(self) self._started = false end
      }
      lastBoundEventTap = tap
      return tap
    end,
    keyStrokes = function(str) lastKeyStrokes = str end
  },
  alert = {
    show = function(msg) lastAlert = msg end
  },
  timer = {
    doAfter = function(sec, fn)
      local t = {
        stop = function() end,
        trigger = fn
      }
      table.insert(timerCallbacks, t)
      return t
    end
  },
  host = {
    _style = "Dark",
    interfaceStyle = function() return _G.hs.host._style end
  },
  distributednotifications = {
    _watchers = {},
    new = function(fn, name)
      local w = {
        callback = fn,
        name = name,
        _started = false,
        start = function(self) self._started = true; return self end,
        stop = function(self) self._started = false; return self end,
        trigger = function(self, obj, info) if self._started and self.callback then self.callback(self.name, obj, info) end end
      }
      table.insert(_G.hs.distributednotifications._watchers, w)
      return w
    end
  },
  menubar = {
    new = function()
      local m = {
        menu = nil,
        title = "",
        icon = nil,
        clickCallback = nil,
        frame = function(self) return { x = 1200, y = 0, w = 24, h = 22 } end,
        setMenu = function(self, menu) self.menu = menu; return self end,
        setClickCallback = function(self, fn) self.clickCallback = fn; return self end,
        setTitle = function(self, t) self.title = t; return self end,
        setIcon = function(self, i) self.icon = i end,
        delete = function(self) self.menu = nil; self.clickCallback = nil end,
        popupMenu = function(self, pos) end
      }
      return m
    end
  },
  chooser = {
    new = function(cb)
      local c = {
        callback = cb,
        _choices = {},
        _placeholder = "",
        _width = nil,
        _rows = nil,
        _bgDark = nil,
        _fgColor = nil,
        _subTextColor = nil,
        _searchSubText = nil,
        _queryChanged = nil,
        _rightClick = nil,
        choices = function(self, ch) self._choices = ch; return self end,
        placeholderText = function(self, txt) self._placeholder = txt; return self end,
        width = function(self, w) self._width = w; return self end,
        rows = function(self, r) self._rows = r; return self end,
        bgDark = function(self, d) self._bgDark = d; return self end,
        fgColor = function(self, col) self._fgColor = col; return self end,
        subTextColor = function(self, col) self._subTextColor = col; return self end,
        searchSubText = function(self, s) self._searchSubText = s; return self end,
        queryChangedCallback = function(self, fn) self._queryChanged = fn; return self end,
        rightClickCallback = function(self, fn) self._rightClick = fn; return self end,
        selectedRowContents = function(self) return self._choices[1] end,
        cancel = function(self) end,
        show = function(self) end
      }
      return c
    end
  },
  canvas = {
    windowLevels = {
      overlay = 100,
      floating = 101,
      desktopIcon = 10
    },
    new = function(frame)
      local c = {
        _frame = frame,
        _elements = {},
        _mouseCb = nil,
        _visible = false,
        _clickAct = true,
        level = function(self, l) self._level = l; return self end,
        clickActivating = function(self, flag) self._clickAct = flag; return self end,
        canvasMouseEvents = function(self, ...) return self end,
        frame = function(self, f) if f then self._frame = f else return self._frame end return self end,
        mouseCallback = function(self, fn) self._mouseCb = fn; return self end,
        imageFromCanvas = function(self) return { _isImage = true } end,
        appendElements = function(self, el)
          if el[1] then
            for _, e in ipairs(el) do table.insert(self._elements, e) end
          else
            table.insert(self._elements, el)
          end
          return self
        end,
        replaceElements = function(self, els)
          self._elements = els
          return self
        end,
        removeElement = function(self, idx)
          if idx then table.remove(self._elements, idx) else table.remove(self._elements) end
          return self
        end,
        show = function(self) self._visible = true; return self end,
        hide = function(self) self._visible = false; return self end,
        delete = function(self) self._elements = {}; self._visible = false end,
      }
      setmetatable(c, {
        __len = function(self) return #self._elements end,
        __index = function(self, k)
          if type(k) == "number" then return self._elements[k] end
        end,
        __newindex = function(self, k, v)
          if type(k) == "number" then self._elements[k] = v end
        end
      })
      return c
    end
  },
  mouse = {
    absolutePosition = function() return { x = 600, y = 400 } end,
    getAbsolutePosition = function() return { x = 600, y = 400 } end,
    getCurrentScreen = function()
      return {
        fullFrame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end
      }
    end
  },
  spoons = {
    bindHotkeysToSpec = function(def, mapping)
      _G.hs.spoons.lastBound = { def = def, mapping = mapping }
    end
  },
  hash = {
    MD5 = function(str)
      return string.format("%08x%08x%08x%08x", 1234, 5678, 9101, 1121)
    end
  }
}

-- Load PasswordGenerator module
local baseDir = "Source/PasswordGenerator.spoon/"
local chunk, err = loadfile(baseDir .. "init.lua")
if not chunk then
  baseDir = "./"
  chunk, err = loadfile("init.lua")
end

if not chunk then
  print("ERROR loading init.lua: " .. tostring(err))
  os.exit(1)
end

local pg = chunk()
pg.spoonPath = baseDir

print("--- Running PasswordGenerator Test Suite ---")

-- Test 1: Randomness & CSPRNG
print("\n[Test 1] Randomness & CSPRNG Sources")
local b = pg.sources.random.csprng.bytes(16)
assert_true(b ~= nil and #b == 16, "csprng.bytes(16) returns 16 bytes")

for i = 1, 50 do
  local val = pg.sources.random.csprng.randomInt(5, 12)
  assert_true(val >= 5 and val <= 12, "csprng.randomInt within bounds: " .. val)
end

-- Test 2: Wordlist Sources
print("\n[Test 2] Wordlist Sources")
local effWords = pg.sources.wordlist.eff_diceware()
assert_true(#effWords >= 1296, "eff_diceware loaded words: " .. #effWords)
assert_true(effWords[1] == "acid", "eff_diceware first word is acid")

local xkcdWords = pg.sources.wordlist.xkcd()
assert_true(#xkcdWords >= 2000, "xkcd loaded words: " .. #xkcdWords)

local diceWords = pg.sources.wordlist.diceware()
assert_true(#diceWords >= 7776, "diceware wordlist loaded 7776 words: " .. #diceWords)
assert_true(diceWords[1] == "abacus", "first diceware word is abacus")

local effLarge = pg.sources.wordlist.eff_large()
assert_equal(7776, #effLarge, "eff_large loaded 7776 words")
assert_equal("abacus", effLarge[1], "eff_large first word is abacus")
assert_equal("zoom", effLarge[#effLarge], "eff_large last word is zoom")
assert_equal(#effLarge, #pg.sources.wordlist.efflarge(), "efflarge alias works")

local effShort = pg.sources.wordlist.eff_short_v2()
assert_equal(1296, #effShort, "eff_short_v2 loaded 1296 words")
assert_equal("aardvark", effShort[1], "eff_short_v2 first word is aardvark")
assert_equal("zucchini", effShort[#effShort], "eff_short_v2 last word is zucchini")
assert_equal(#effShort, #pg.sources.wordlist.effshortv2(), "effshortv2 alias works")
assert_equal(#effShort, #pg.sources.wordlist.eff_short(), "eff_short alias works")

local trekWords = pg.sources.wordlist.star_trek()
assert_equal(4000, #trekWords, "star_trek loaded 4000 words")
assert_equal(#trekWords, #pg.sources.wordlist.startrek(), "startrek alias works")
assert_equal(#trekWords, #pg.sources.wordlist["star-trek"](), "star-trek alias works")

local warsWords = pg.sources.wordlist.star_wars()
assert_equal(4000, #warsWords, "star_wars loaded 4000 words")
assert_equal(#warsWords, #pg.sources.wordlist.starwars(), "starwars alias works")
assert_equal(#warsWords, #pg.sources.wordlist["star-wars"](), "star-wars alias works")

local potterWords = pg.sources.wordlist.harry_potter()
assert_equal(4000, #potterWords, "harry_potter loaded 4000 words")
assert_equal(#potterWords, #pg.sources.wordlist.harrypotter(), "harrypotter alias works")
assert_equal(#potterWords, #pg.sources.wordlist["harry-potter"](), "harry-potter alias works")

-- Test 3: Algorithm - random / charset
print("\n[Test 3] Algorithm: random")
local p1 = pg:generate({ algorithm = "random", length = 24 })
assert_equal(24, #p1, "random length 24")
assert_match("%u", p1, "random contains uppercase")
assert_match("%l", p1, "random contains lowercase")
assert_match("%d", p1, "random contains digits")
assert_match("[%p%s!@#$%%^&*()_%-=+]", p1, "random contains symbols")

-- Disabling symbols
local pNoSym = pg:generate({ algorithm = "random", length = 20, symbols = false })
assert_equal(20, #pNoSym, "no symbols length 20")
assert_true(not pNoSym:match("[!@#$%^&*()_%-=+{}%[%]|;:,.<>?/~`'\"]"), "no symbols in alphanumeric password")

-- Excluding ambiguous characters
local pNoAmb = pg:generate({ algorithm = "random", length = 60, exclude_ambiguous = true })
assert_true(not pNoAmb:match("[0O1lI|`'\"~]"), "no ambiguous characters in password: " .. pNoAmb)

-- Custom charset
local pCustom = pg:generate({ algorithm = "random", length = 15, custom_charset = "ACTG" })
assert_equal(15, #pCustom, "custom charset length 15")
assert_match("^[ACTG]+$", pCustom, "only contains custom charset characters")

-- Test 4: Algorithm - diceware (Authentic 5-Dice)
print("\n[Test 4] Algorithm: diceware (5-dice rolls)")
local dw1 = pg:generate({ algorithm = "diceware", word_count = 5 })
local dwWords = {}
for w in dw1:gmatch("%S+") do table.insert(dwWords, w) end
assert_equal(5, #dwWords, "diceware generates 5 space-separated words: " .. dw1)

local dw6 = pg:generate({ algorithm = "diceware", word_count = 6, separator = "-" })
local dw6Words = {}
for w in dw6:gmatch("[^-]+") do table.insert(dw6Words, w) end
assert_equal(6, #dw6Words, "diceware generates 6 hyphen-separated words: " .. dw6)

local dwTitle = pg:generate({ algorithm = "diceware", word_count = 4, capitalize = "title" })
assert_match("^%u%l+", dwTitle, "diceware title case capitalizes first letter")

-- Test 5: Algorithm - passphrase / xkcd
print("\n[Test 5] Algorithm: passphrase")
local pass1 = pg:generate({ algorithm = "passphrase", word_count = 4, separator = "-" })
local words1 = {}
for w in pass1:gmatch("[^-]+") do table.insert(words1, w) end
assert_equal(4, #words1, "passphrase has 4 words separated by '-'")
assert_match("^%u%l+", words1[1], "word is capitalized in title case")

local passDots = pg:generate({ algorithm = "passphrase", word_count = 3, separator = "." })
assert_match("^[^%.]+%.[^%.]+%.[^%.]+$", passDots, "passphrase separated by '.'")

local passNum = pg:generate({ algorithm = "passphrase", word_count = 3, include_number = true })
assert_match("%d", passNum, "passphrase includes number")

local passSym = pg:generate({ algorithm = "passphrase", word_count = 3, include_symbol = true })
assert_match("[!@#$%%%^&*]", passSym, "passphrase includes symbol")

local pTrek = pg:generate({ algorithm = "passphrase", word_source = "star_trek", word_count = 4, separator = "-" })
local trekParts = {}
for w in pTrek:gmatch("[^-]+") do table.insert(trekParts, w) end
assert_equal(4, #trekParts, "star_trek word source generates 4 hyphenated words: " .. pTrek)

local pWars = pg:generate({ algorithm = "star_wars", word_count = 4, separator = "_" })
local warsParts = {}
for w in pWars:gmatch("[^_]+") do table.insert(warsParts, w) end
assert_equal(4, #warsParts, "star_wars algorithm shortcut generates 4 underscore words: " .. pWars)

local pPotter = pg:generate({ algorithm = "harry_potter", word_count = 5, separator = " " })
local potterParts = {}
for w in pPotter:gmatch("%S+") do table.insert(potterParts, w) end
assert_equal(5, #potterParts, "harry_potter algorithm shortcut generates 5 words: " .. pPotter)

local pEffLarge = pg:generate({ algorithm = "eff_large", word_count = 6, separator = "." })
local effLargeParts = {}
for w in pEffLarge:gmatch("[^%.]+") do table.insert(effLargeParts, w) end
assert_equal(6, #effLargeParts, "eff_large algorithm shortcut generates 6 words: " .. pEffLarge)

local pEffShort = pg:generate({ algorithm = "eff_short_v2", word_count = 4, separator = "/" })
local effShortParts = {}
for w in pEffShort:gmatch("[^/]+") do table.insert(effShortParts, w) end
assert_equal(4, #effShortParts, "eff_short_v2 algorithm shortcut generates 4 words: " .. pEffShort)

-- Test 6: Algorithm - pin
print("\n[Test 6] Algorithm: pin")
local pin6 = pg:generate({ algorithm = "pin", length = 6 })
assert_equal(6, #pin6, "PIN has 6 digits")
assert_match("^%d+$", pin6, "PIN is numeric only")

local pin4 = pg:generate({ algorithm = "pin", length = 4 })
assert_equal(4, #pin4, "PIN has 4 digits")

for _ = 1, 20 do
  local p = pg:generate({ algorithm = "pin", length = 4, allow_sequences = false })
  assert_true(p ~= "1234" and p ~= "4321" and p ~= "0000" and p ~= "1111", "PIN does not generate simple sequences")
end

-- Test 7: Algorithm - pattern mask
print("\n[Test 7] Algorithm: pattern")
local pat1 = pg:generate({ algorithm = "pattern", mask = "Ulll-dddd-SSSS" })
assert_equal(14, #pat1, "pattern length matches template")
assert_match("^%u%l%l%l%-%d%d%d%d%-[^%w%s][^%w%s][^%w%s][^%w%s]$", pat1, "pattern matches mask: " .. pat1)

local patEsc = pg:generate({ algorithm = "pattern", mask = "\\U\\d-dd" })
assert_match("^Ud%-%d%d$", patEsc, "pattern handles escaped literal characters: " .. patEsc)

-- Test 8: Algorithm - pronounceable
print("\n[Test 8] Algorithm: pronounceable")
local pron = pg:generate({ algorithm = "pronounceable", length = 12 })
assert_equal(12, #pron, "pronounceable length 12")
assert_match("%d$", pron, "pronounceable ends with digit")

-- Test 9: Algorithm - token
print("\n[Test 9] Algorithm: token")
local hexToken = pg:generate({ algorithm = "token", format = "hex", length = 32 })
assert_equal(32, #hexToken, "hex token length 32")
assert_match("^[0-9a-f]+$", hexToken, "hex token format valid")

local b64Token = pg:generate({ algorithm = "token", format = "base64", length = 20 })
assert_equal(20, #b64Token, "base64 token length 20")

local b64Url = pg:generate({ algorithm = "token", format = "base64url", length = 25 })
assert_equal(25, #b64Url, "base64url token length 25")
assert_true(not b64Url:match("[+/]"), "base64url has no + or / characters")

local uuid = pg:generate({ algorithm = "token", format = "uuid4" })
assert_equal(36, #uuid, "UUID length is 36")
assert_match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$", uuid, "valid UUIDv4 format: " .. uuid)

-- Test 10: Configurable Preset Items
print("\n[Test 10] Configurable Preset Items")
local items = pg:listItems()
assert_true(#items >= 7, "has default preset items (including diceware): " .. #items)

local dwItem = pg:getItem("diceware")
assert_true(dwItem ~= nil, "found diceware item preset")
assert_equal("diceware", dwItem.algorithm, "diceware algorithm is diceware")
assert_equal(5, dwItem.word_count, "diceware word count is 5")

local pwdDice = pg:generate("diceware")
assert_true(pwdDice ~= nil and #pwdDice > 15, "generated diceware password from preset item: " .. pwdDice)

assert_true(pg:getItem("eff_large") ~= nil, "found eff_large item preset")
assert_true(pg:getItem("eff_short_v2") ~= nil, "found eff_short_v2 item preset")
assert_true(pg:getItem("star_trek") ~= nil, "found star_trek item preset")
assert_true(pg:getItem("star_wars") ~= nil, "found star_wars item preset")
assert_true(pg:getItem("harry_potter") ~= nil, "found harry_potter item preset")

local pwdTrek = pg:generate("star_trek")
assert_true(pwdTrek ~= nil and #pwdTrek > 10, "generated star_trek password from preset: " .. pwdTrek)

local pwdEff = pg:generate("eff_large")
assert_true(pwdEff ~= nil and #pwdEff > 15, "generated eff_large password from preset: " .. pwdEff)

-- Adding a custom item
pg:addItem({
  id = "vpn",
  title = "Company VPN Token",
  algorithm = "token",
  format = "hex",
  length = 16
})
assert_true(pg:getItem("vpn") ~= nil, "custom item 'vpn' added")
local vpnPwd = pg:generate("vpn")
assert_equal(16, #vpnPwd, "generate('vpn') produced 16 hex chars")
assert_match("^[0-9a-f]+$", vpnPwd, "vpn token is hex")

pg:removeItem("vpn")
assert_true(pg:getItem("vpn") == nil, "custom item 'vpn' removed")

-- Test 11: Extensibility: Custom Algorithm & Wordlist Registration
print("\n[Test 11] Extensibility: Custom Algorithm & Wordlist Registration")
pg:registerAlgorithm("rot13_fixed", function(self, opts)
  return "custom_algo_result"
end)
local customRes = pg:generate({ algorithm = "rot13_fixed" })
assert_equal("custom_algo_result", customRes, "custom algorithm executed successfully")

pg:registerWordSource("mythology", { "zeus", "apollo", "athena", "ares", "hermes" })
local mythPass = pg:generate({ algorithm = "passphrase", word_source = "mythology", word_count = 3, separator = "_" })
assert_match("^[A-Z][a-z]+_[A-Z][a-z]+_[A-Z][a-z]+$", mythPass, "custom word source generated passphrase: " .. mythPass)

-- Test 12: Clipboard & Actions
print("\n[Test 12] Clipboard & Actions")
clipboardContent = nil
local cpResult = pg:copyPassword("pin")
assert_equal(clipboardContent, cpResult, "copyPassword updated system clipboard")
assert_equal(6, #clipboardContent, "copied PIN length is 6")
assert_equal("PIN Code (6 digits) copied to clipboard", lastAlert, "safe notification shown with exact selected digits")

-- Notification formatting tests
pg:copyPassword({ id = "strong", title = "Strong Password", length = 28 })
assert_equal("Strong Password (28 chars) copied to clipboard", lastAlert, "notification shows selected chars without static text")

pg:copyPassword({ id = "diceware", title = "Diceware", word_count = 6 })
assert_equal("Diceware (6 words) copied to clipboard", lastAlert, "notification shows selected words without static text")

pg:copyPassword({ id = "custom", title = "My Vault (16 chars)", length = 32 })
assert_equal("My Vault (32 chars) copied to clipboard", lastAlert, "static length in custom title stripped without duplication")

assert_true(#timerCallbacks > 0, "auto-clear timer was scheduled")
timerCallbacks[#timerCallbacks].trigger()
assert_equal(nil, clipboardContent, "clipboard auto-cleared by timeout timer")
assert_match("sanitized", lastAlert, "clipboard sanitization alert shown")

lastKeyStrokes = nil
local pasteResult = pg:pastePassword("pin")
assert_equal(pasteResult, lastKeyStrokes, "pastePassword called eventtap.keyStrokes with generated password")

-- Test 13: Interactive Menubar Dropdown Menu
print("\n[Test 13] Interactive Menubar Dropdown Menu")

-- Verify entropy calculations for all algorithms
assert_true(pg:calculateEntropy("strong", 20) >= 120, "strong password 20 chars entropy >= 120 bits")
assert_true(pg:calculateEntropy("diceware", 5) >= 64, "diceware 5 words entropy >= 64 bits")
assert_true(pg:calculateEntropy("passphrase", 4) >= 40, "passphrase 4 words entropy >= 40 bits")
assert_true(pg:calculateEntropy("eff_large", 5) >= 64, "eff_large 5 words entropy >= 64 bits")
assert_true(pg:calculateEntropy("eff_short_v2", 5) >= 51, "eff_short_v2 5 words entropy >= 51 bits")
assert_true(pg:calculateEntropy("star_trek", 4) >= 47 and pg:calculateEntropy("star_trek", 4) <= 48, "star_trek 4 words entropy ~ 47.86 bits")
assert_true(pg:calculateEntropy("star_wars", 4) >= 47 and pg:calculateEntropy("star_wars", 4) <= 48, "star_wars 4 words entropy ~ 47.86 bits")
assert_true(pg:calculateEntropy("harry_potter", 4) >= 47 and pg:calculateEntropy("harry_potter", 4) <= 48, "harry_potter 4 words entropy ~ 47.86 bits")
assert_true(pg:calculateEntropy("pin", 6) >= 19 and pg:calculateEntropy("pin", 6) <= 21, "pin 6 digits entropy ~ 19.9 bits")
assert_equal(128, pg:calculateEntropy("hex_token", 32), "hex token 32 chars entropy == 128 bits")
assert_true(pg:calculateEntropy("alphanumeric", 16) >= 90, "alphanumeric 16 chars entropy >= 90 bits")
assert_true(pg:calculateEntropy("pronounceable", 12) >= 40, "pronounceable 12 chars entropy >= 40 bits")

-- Verify crack time estimation
assert_equal("instant", pg:calculateCrackTime(0), "0 bits crack time is instant")
assert_equal("instant", pg:calculateCrackTime(19.9), "pin 6 digits crack time is instant")
assert_match("minute", pg:calculateCrackTime(43.2), "43 bits crack time in minutes")
assert_match("day", pg:calculateCrackTime(51.7), "51.7 bits crack time in days")
assert_match("year", pg:calculateCrackTime(64.6), "64.6 bits crack time in years")
assert_equal(">100m years", pg:calculateCrackTime(126.4), "126 bits crack time >100m years")
assert_equal(">100m years", pg:calculateCrackTime(164.5), "164.5 bits crack time >100m years")

-- Verify strength info calculation
local pinStr = pg:getStrengthInfo("pin", 6)
assert_equal("Very Weak", pinStr.rating, "pin 6 rating is Very Weak")
assert_equal(1, pinStr.score, "pin 6 score is 1")
assert_equal("instant", pinStr.crackTime, "pin 6 crack time is instant")
assert_match("Very Weak %(6 / 19%.9 bits / instant%)", pinStr.label, "pin strength label format")

local strongStr = pg:getStrengthInfo("strong", 20)
assert_equal("Very Strong", strongStr.rating, "strong 20 rating is Very Strong")
assert_equal(5, strongStr.score, "strong 20 score is 5")
assert_equal(">100m years", strongStr.crackTime, "strong 20 crack time is >100m years")
assert_match("Very Strong %(20 / 126%.4 bits / >100m years%)", strongStr.label, "strong strength label format")

-- Verify all items display bits and crack time in strength label, and have uniform slider color
for idx, item in ipairs(pg.items) do
  pg.interactiveState.activeItemIndex = idx
  local _, _, spec = pg:_getInteractiveItemOpts()
  assert_match("bits", spec.formatLabel(spec.defaultVal), "item " .. item.id .. " formatLabel displays bits")
  assert_equal(1.0, spec.color.blue, "item " .. item.id .. " uses uniform pastel sky blue slider")
  assert_equal(0.65, spec.color.red, "item " .. item.id .. " does not use odd-out green slider")
end

-- Open menu
pg:showInteractiveMenu()
assert_true(pg.interactiveCanvas ~= nil, "interactive menu canvas initialized")
assert_true(pg.interactiveCanvas._visible == true, "interactive menu visible")
assert_true(#pg.interactiveCanvas._elements > 20, "interactive menu has rendered rich elements: " .. #pg.interactiveCanvas._elements)

-- Verify strength meter bar is rendered above readout
local strengthMeterFound = false
for _, el in ipairs(pg.interactiveCanvas._elements) do
  if el.type == "rectangle" and el.action == "fill" and el.frame.y == 37 and el.frame.h == 3 then
    strengthMeterFound = true
    break
  end
end
assert_true(strengthMeterFound, "horizontal strength meter bar rendered at y=37, h=3")

-- Verify distinct high-contrast button styling and equal padding on active row
local activeBtnFound = false
local activeRowRect, activeBtnRect = nil, nil
for _, el in ipairs(pg.interactiveCanvas._elements) do
  if el.type == "rectangle" and el.action == "strokeAndFill" and el.frame.h == 26 and el.frame.x == 12 then
    activeRowRect = el.frame
  elseif el.id == "quick_copy_" .. pg.items[pg.interactiveState.activeItemIndex].id and el.type == "rectangle" then
    assert_equal(0.85, el.fillColor.blue, "active row copy button has distinct accent blue fill")
    assert_equal("strokeAndFill", el.action, "active row copy button has strokeAndFill border")
    activeBtnRect = el.frame
    activeBtnFound = true
  end
end
assert_true(activeBtnFound, "active row copy button found with distinct accent styling")
if activeRowRect and activeBtnRect then
  local topPad = activeBtnRect.y - activeRowRect.y
  local bottomPad = (activeRowRect.y + activeRowRect.h) - (activeBtnRect.y + activeBtnRect.h)
  local rightPad = (activeRowRect.x + activeRowRect.w) - (activeBtnRect.x + activeBtnRect.w)
  assert_equal(topPad, bottomPad, "top and bottom padding around copy button are equal: " .. topPad)
  assert_equal(topPad, rightPad, "top and right padding around copy button match: " .. topPad)
end

-- Verify system theme colors and Light / Dark adaptation
local darkTheme = pg:getThemeColors(true)
assert_true(darkTheme.isDark == true, "dark theme isDark is true")
assert_true(darkTheme.panelBg.red < 0.2, "dark theme panelBg is dark")
assert_equal(0.95, darkTheme.panelBg.alpha, "dark theme default menu opacity is 0.95")
assert_true(darkTheme.headerText.white > 0.9, "dark theme header text is bright")

local lightTheme = pg:getThemeColors(false)
assert_true(lightTheme.isDark == false, "light theme isDark is false")
assert_true(lightTheme.panelBg.red > 0.9, "light theme panelBg is bright")
assert_equal(0.96, lightTheme.panelBg.alpha, "light theme default menu opacity is 0.96")
assert_true(lightTheme.headerText.white < 0.2, "light theme header text is dark")
assert_equal(1.0, lightTheme.copyBtnActiveText.white, "light theme active copy button text is white")
assert_equal(1.0, lightTheme.copyBtnActiveFill.blue, "light theme active copy button fill is accent blue")

-- Test menu opacity setting
pg:setMenuOpacity(0.75)
assert_equal(0.75, pg:getThemeColors().panelBg.alpha, "custom menu_opacity reflected in getThemeColors")
assert_equal(0.75, pg.interactiveCanvas._elements[1].fillColor.alpha, "custom menu_opacity reflected on canvas background")
pg:setMenuOpacity(nil)
assert_equal(0.95, pg:getThemeColors(true).panelBg.alpha, "menu_opacity reset to default")

-- Test menu corner radius (default 14pt matching macOS native menus)
assert_equal(14, pg.menu_corner_radius, "default menu corner radius is 14pt matching native menus")
assert_equal(14, pg.interactiveCanvas._elements[1].roundedRectRadii.xRadius, "canvas background has 14pt corner radius")
pg:setMenuCornerRadius(18)
assert_equal(18, pg.interactiveCanvas._elements[1].roundedRectRadii.xRadius, "setMenuCornerRadius(18) updates canvas corner radius")
pg:setMenuCornerRadius(14)

-- Test switching theme dynamically
pg:setTheme("light")
assert_equal(false, pg:_isDarkMode(), "setTheme('light') sets mode to light")
local lightBg = pg.interactiveCanvas._elements[1]
assert_true(lightBg.fillColor.red > 0.9, "rendered menu background in light mode is light")
assert_true(lightBg.strokeColor.alpha < 0.3, "rendered menu border in light mode is subtle")

pg:setTheme("dark")
assert_equal(true, pg:_isDarkMode(), "setTheme('dark') sets mode to dark")
local darkBg = pg.interactiveCanvas._elements[1]
assert_true(darkBg.fillColor.red < 0.2, "rendered menu background in dark mode is dark")

-- Test AppleInterfaceThemeChangedNotification distribution
pg:setTheme("system")
assert_equal("system", pg.theme, "theme restored to system")
_G.hs.host._style = "Light"
for _, w in ipairs(_G.hs.distributednotifications._watchers) do
  if w.name == "AppleInterfaceThemeChangedNotification" then
    w:trigger()
  end
end
local liveLightBg = pg.interactiveCanvas._elements[1]
assert_true(liveLightBg.fillColor.red > 0.9, "menu automatically adapted to Light appearance via theme notification")

_G.hs.host._style = "Dark"
for _, w in ipairs(_G.hs.distributednotifications._watchers) do
  if w.name == "AppleInterfaceThemeChangedNotification" then
    w:trigger()
  end
end
local liveDarkBg = pg.interactiveCanvas._elements[1]
assert_true(liveDarkBg.fillColor.red < 0.2, "menu automatically adapted to Dark appearance via theme notification")

-- Verify mouse movement over slider bar changes length
local initialLen = pg.interactiveState.currentLength
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseMove", "slider_bar", 200, 68)
local updatedLen = pg.interactiveState.currentLength
assert_true(updatedLen ~= nil, "mouseMove over segmented bar updated length: " .. tostring(updatedLen))
assert_true(#pg.interactiveState.previewPassword > 0, "previewPassword generated: " .. pg.interactiveState.previewPassword)

-- Select Diceware preset row (item_row_2)
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "item_row_2", 100, 185)
assert_equal(2, pg.interactiveState.activeItemIndex, "switched active preset to Diceware (row 2)")
local curItem = pg.items[pg.interactiveState.activeItemIndex]
assert_equal("diceware", curItem.id, "active preset is diceware")

-- Quick copy button on preset row (e.g. quick_copy_pin)
clipboardContent = nil
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "quick_copy_pin", 340, 240)
assert_equal(6, #clipboardContent, "quick copy button generated and copied 6-digit PIN")
assert_equal(nil, pg.interactiveCanvas, "menu closed after quick copy")

-- User Reported Scenario: Switch to PIN, change length to 16, switch to Alphanumeric, switch back to PIN
pg:showInteractiveMenu()
-- 1. Switch to PIN (item_row_4)
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "item_row_4", 100, 240)
assert_equal(4, pg.interactiveState.activeItemIndex, "switched to PIN")
assert_equal(6, pg.interactiveState.currentLength, "initial PIN length is default 6")
assert_equal(6, #pg.interactiveState.previewPassword, "preview PIN length matches default 6")

-- 2. Move slider to max length (16 digits)
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseMove", "slider_bar", 350, 68)
assert_equal(16, pg.interactiveState.currentLength, "PIN slider changed to 16 digits")
assert_equal(16, #pg.interactiveState.previewPassword, "preview PIN length updated to 16 digits")

-- 3. Switch to Alphanumeric (item_row_5, default 16 chars)
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "item_row_5", 100, 270)
assert_equal(5, pg.interactiveState.activeItemIndex, "switched to Alphanumeric")
assert_equal(16, pg.interactiveState.currentLength, "Alphanumeric length is default 16")
assert_equal(16, #pg.interactiveState.previewPassword, "preview Alphanumeric length is 16")

-- 4. Switch back to PIN (item_row_4)
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "item_row_4", 100, 240)
assert_equal(4, pg.interactiveState.activeItemIndex, "switched back to PIN")
assert_equal(6, pg.interactiveState.currentLength, "PIN length reset to default 6")
assert_equal(6, #pg.interactiveState.previewPassword, "preview PIN length is 6 digits (NOT old 16)")

-- Click preview box and verify copied PIN is 6 digits and matches preview exactly
clipboardContent = nil
local displayedPin = pg.interactiveState.previewPassword
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "btn_preview_click", 100, 100)
assert_equal(6, #clipboardContent, "copied PIN from preview box is 6 digits")
assert_equal(displayedPin, clipboardContent, "preview box click copies the EXACT displayed text")

-- Verify slider click copies the exact displayed preview password
pg:showInteractiveMenu()
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseMove", "slider_bar", 250, 68)
local displayedSlider = pg.interactiveState.previewPassword
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "slider_bar", 250, 68)
assert_equal(displayedSlider, clipboardContent, "slider click copies the EXACT displayed text")

-- Verify active row quick copy button copies the exact displayed preview password
pg:showInteractiveMenu()
local activeId = pg.items[pg.interactiveState.activeItemIndex].id
local displayedActive = pg.interactiveState.previewPassword
pg:_handleInteractiveMouse(pg.interactiveCanvas, "mouseDown", "quick_copy_" .. activeId, 340, 160)
assert_equal(displayedActive, clipboardContent, "active row quick copy copies the EXACT displayed text")

-- Verify modern hs.mouse.absolutePosition vs legacy getAbsolutePosition
local calledModern = false
local calledLegacy = false
local oldAbsolute = _G.hs.mouse.absolutePosition
local oldGetAbsolute = _G.hs.mouse.getAbsolutePosition

_G.hs.mouse.absolutePosition = function() calledModern = true return { x = 500, y = 300 } end
_G.hs.mouse.getAbsolutePosition = nil
pg:showInteractiveMenu()
assert_true(calledModern, "used modern hs.mouse.absolutePosition when available")
pg:hideInteractiveMenu()

calledModern = false
_G.hs.mouse.absolutePosition = nil
_G.hs.mouse.getAbsolutePosition = function() calledLegacy = true return { x = 500, y = 300 } end
pg:showInteractiveMenu()
assert_true(calledLegacy, "fell back to legacy hs.mouse.getAbsolutePosition when absolutePosition is nil")
pg:hideInteractiveMenu()

_G.hs.mouse.absolutePosition = oldAbsolute
_G.hs.mouse.getAbsolutePosition = oldGetAbsolute

-- Toggle interactive menu
pg:toggleInteractiveMenu()
assert_true(pg.interactiveCanvas ~= nil and pg.interactiveCanvas._visible, "toggle opened menu")
pg:toggleInteractiveMenu()
assert_equal(nil, pg.interactiveCanvas, "toggle closed menu")

-- Test 14: Legacy Backward Compatibility
print("\n[Test 14] Legacy Backward Compatibility")
pg.password_style = "xkcd"
local legacyXkcd = pg:generate()
assert_match("%a+", legacyXkcd, "legacy xkcd style generated password: " .. legacyXkcd)

pg.password_generator_function = function(s) return "legacy_override_999" end
local legacyCustom = pg:generate()
assert_equal("legacy_override_999", legacyCustom, "legacy generator function override honored")
local getterFn = pg:getPasswordGenerator()
assert_equal("legacy_override_999", getterFn(pg), "getPasswordGenerator returns legacy function")
pg.password_generator_function = nil
pg.password_style = "default"

-- Test 15: Menubar Integration & Hotkeys
print("\n[Test 15] Menubar Integration & Hotkeys")
-- 1. With interactive_menu = true (default)
pg.interactive_menu = true
pg:start()
assert_true(pg.menubar ~= nil, "menubar initialized")
assert_true(pg.menubar.clickCallback ~= nil, "menubar clickCallback registered for interactive menu")

-- Simulate clicking menubar item
pg.menubar.clickCallback()
assert_true(pg.interactiveCanvas ~= nil and pg.interactiveCanvas._visible, "clicking menubar opened interactive menu")
pg.menubar.clickCallback()
assert_equal(nil, pg.interactiveCanvas, "clicking menubar second time closed interactive menu")

-- 2. With interactive_menu = false (fallback mode)
pg.interactive_menu = false
pg:_updateMenubar()
assert_true(pg.menubar.menu ~= nil and #pg.menubar.menu >= 7, "fallback native menu configured")

-- showChooser backward compatibility alias toggles interactive menu
pg:showChooser()
assert_true(pg.interactiveCanvas ~= nil and pg.interactiveCanvas._visible, "showChooser opens interactive menu")
pg:showChooser()
assert_equal(nil, pg.interactiveCanvas, "showChooser second invocation closes interactive menu")

-- Hotkey bindings
pg:bindHotkeys({
  copy = { { "cmd", "alt" }, "c" },
  menu = { { "cmd", "alt" }, "m" },
  diceware = { { "cmd", "alt" }, "d" },
  pin = { { "cmd", "alt" }, "p" }
})
assert_true(_G.hs.spoons.lastBound ~= nil, "hotkeys bound via hs.spoons.bindHotkeysToSpec")
assert_true(_G.hs.spoons.lastBound.def.menu ~= nil, "menu hotkey bound to interactive menu")
assert_true(_G.hs.spoons.lastBound.def.diceware ~= nil, "diceware hotkey bound")

pg:stop()
assert_equal(nil, pg.menubar, "menubar cleaned up on stop()")

print(string.format("\n========================================="))
print(string.format("Test Results: %d Passed, %d Failed", passed, failed))
print(string.format("========================================="))

if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
