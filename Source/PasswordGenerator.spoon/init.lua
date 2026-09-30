--- === PasswordGenerator ===
---
--- Multi-algorithm, cryptographically secure password and passphrase generator with configurable preset items, interactive menubar dropdown menu, and segmented-bar length selector.
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/PasswordGenerator.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/PasswordGenerator.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "PasswordGenerator"
obj.version = "2.3"
obj.author = "Jon Lorusso <jonlorusso@gmail.com>, modern overhaul"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local function script_path()
  local info = debug.getinfo(2, "S")
  if info and info.source then
    local str = info.source:sub(2)
    local p = str:match("(.*/)")
    if p then return p end
  end
  return "./"
end
obj.spoonPath = script_path()

-- Safely resolve Hammerspoon modules
local has_hs = type(hs) == "table"
local getSetting = function(label, default)
  if has_hs and hs.settings and hs.settings.get then
    local val = hs.settings.get(obj.name .. "." .. label)
    if val ~= nil then return val end
  end
  return default
end

-- Seed math.random with high-resolution time for fallback PRNG
math.randomseed(os.time() + (os.clock and math.floor(os.clock() * 1000000) or 0))

--------------------------------------------------------------------------------
-- Entropy & Randomness Sources
--------------------------------------------------------------------------------

obj.sources = {
  random = {},
  wordlist = {}
}

-- Read n cryptographically secure pseudo-random bytes from /dev/urandom
local function csprng_bytes(n)
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(n)
    f:close()
    if bytes and #bytes == n then
      return bytes
    end
  end
  return nil
end

-- CSPRNG Integer generator with rejection sampling to eliminate modulo bias
local function csprng_random_int(min, max)
  if min > max then min, max = max, min end
  local range = max - min + 1
  if range <= 1 then return min end

  -- For small ranges (<= 256), use single byte
  if range <= 256 then
    local limit = 256 - (256 % range)
    for _ = 1, 32 do
      local b = csprng_bytes(1)
      if b then
        local val = string.byte(b, 1)
        if val < limit then
          return min + (val % range)
        end
      else
        break
      end
    end
  else
    -- For larger ranges, use 4 bytes (32-bit unsigned)
    local limit = 4294967296 - (4294967296 % range)
    for _ = 1, 32 do
      local b = csprng_bytes(4)
      if b then
        local b1, b2, b3, b4 = string.byte(b, 1, 4)
        local val = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        if val < limit then
          return min + (val % range)
        end
      else
        break
      end
    end
  end

  -- Fallback to math.random if /dev/urandom is unavailable
  return math.random(min, max)
end

obj.sources.random.csprng = {
  bytes = csprng_bytes,
  randomInt = csprng_random_int
}

obj.sources.random.math_random = {
  bytes = function(n)
    local t = {}
    for i = 1, n do
      t[i] = string.char(math.random(0, 255))
    end
    return table.concat(t)
  end,
  randomInt = function(min, max)
    return math.random(min, max)
  end
}

-- Return active random integer generator based on source
local function getRandomInt(sourceName, min, max)
  local src = obj.sources.random[sourceName or obj.random_source] or obj.sources.random.csprng
  return src.randomInt(min, max)
end

-- Fisher-Yates array shuffle using specified random source
local function shuffleTable(t, sourceName)
  for i = #t, 2, -1 do
    local j = getRandomInt(sourceName, 1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

--------------------------------------------------------------------------------
-- Wordlist Sources
--------------------------------------------------------------------------------

local cached_wordlists = {}
local diceware_words_table = nil
local diceware_dice_map = nil

local function load_wordlist_file(filename)
  if cached_wordlists[filename] then
    return cached_wordlists[filename]
  end

  local list = {}
  local paths_to_try = {
    filename,
    obj.spoonPath .. "/" .. filename,
    obj.spoonPath .. filename
  }

  local file = nil
  for _, p in ipairs(paths_to_try) do
    file = io.open(p, "r")
    if file then break end
  end

  if file then
    for line in file:lines() do
      local code, word = line:match("^(%d+)%s+(%S+)")
      if not word then
        word = line:match("^%s*(.-)%s*$")
      end
      if word and #word > 0 then
        table.insert(list, word:lower())
      end
    end
    file:close()
  end

  cached_wordlists[filename] = list
  return list
end

-- Loads authentic 7,776-word Diceware list with 5-dice code map
local function load_diceware_words()
  if diceware_words_table then
    return diceware_words_table, diceware_dice_map
  end

  local list = {}
  local map = {}
  local paths_to_try = {
    "diceware_words.txt",
    obj.spoonPath .. "/diceware_words.txt",
    obj.spoonPath .. "diceware_words.txt"
  }

  local file = nil
  for _, p in ipairs(paths_to_try) do
    file = io.open(p, "r")
    if file then break end
  end

  if file then
    for line in file:lines() do
      local code, word = line:match("^(%d+)%s+(%S+)")
      if code and word then
        map[code] = word:lower()
        table.insert(list, word:lower())
      else
        local w = line:match("^%s*(.-)%s*$")
        if w and #w > 0 then
          table.insert(list, w:lower())
        end
      end
    end
    file:close()
  end

  if #list == 0 then
    list = load_wordlist_file("eff_words.txt")
  end
  if #list == 0 then
    list = load_wordlist_file("xkcdwords.txt")
  end

  diceware_words_table = list
  diceware_dice_map = map
  return list, map
end

-- Roll five 6-sided dice to produce an authentic Diceware word
local function rollDiceWord(sourceName)
  local list, map = load_diceware_words()
  if map and next(map) ~= nil then
    local d1 = getRandomInt(sourceName, 1, 6)
    local d2 = getRandomInt(sourceName, 1, 6)
    local d3 = getRandomInt(sourceName, 1, 6)
    local d4 = getRandomInt(sourceName, 1, 6)
    local d5 = getRandomInt(sourceName, 1, 6)
    local code = string.format("%d%d%d%d%d", d1, d2, d3, d4, d5)
    local word = map[code]
    if word then return word, code end
  end
  local idx = getRandomInt(sourceName, 1, #list)
  return list[idx] or "word", nil
end

obj.sources.wordlist.diceware = function()
  local list, _ = load_diceware_words()
  return list
end

obj.sources.wordlist.eff_diceware = function()
  local list = load_wordlist_file("eff_words.txt")
  if #list > 0 then return list end
  return load_wordlist_file("xkcdwords.txt")
end

obj.sources.wordlist.eff_large = function()
  return load_wordlist_file("eff_large.txt")
end
obj.sources.wordlist.efflarge = obj.sources.wordlist.eff_large

obj.sources.wordlist.eff_short_v2 = function()
  return load_wordlist_file("eff_short_v2.txt")
end
obj.sources.wordlist.effshortv2 = obj.sources.wordlist.eff_short_v2
obj.sources.wordlist.eff_short = obj.sources.wordlist.eff_short_v2

obj.sources.wordlist.star_trek = function()
  return load_wordlist_file("startrek_words.txt")
end
obj.sources.wordlist.startrek = obj.sources.wordlist.star_trek
obj.sources.wordlist["star-trek"] = obj.sources.wordlist.star_trek

obj.sources.wordlist.star_wars = function()
  return load_wordlist_file("starwars_words.txt")
end
obj.sources.wordlist.starwars = obj.sources.wordlist.star_wars
obj.sources.wordlist["star-wars"] = obj.sources.wordlist.star_wars

obj.sources.wordlist.harry_potter = function()
  return load_wordlist_file("harrypotter_words.txt")
end
obj.sources.wordlist.harrypotter = obj.sources.wordlist.harry_potter
obj.sources.wordlist["harry-potter"] = obj.sources.wordlist.harry_potter

obj.sources.wordlist.xkcd = function()
  return load_wordlist_file("xkcdwords.txt")
end

obj.sources.wordlist.system = function()
  if cached_wordlists["__system__"] then
    return cached_wordlists["__system__"]
  end
  local list = {}
  local f = io.open("/usr/share/dict/words", "r")
  if f then
    for line in f:lines() do
      local word = line:match("^%s*(.-)%s*$")
      -- Filter to pure ascii letters between 3 and 8 chars
      if word and #word >= 3 and #word <= 8 and word:match("^[A-Za-z]+$") then
        table.insert(list, word:lower())
      end
    end
    f:close()
  end
  if #list == 0 then
    list = obj.sources.wordlist.eff_diceware()
  end
  cached_wordlists["__system__"] = list
  return list
end

--------------------------------------------------------------------------------
-- Character Sets & Presets
--------------------------------------------------------------------------------

local CHARSETS = {
  upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
  lower = "abcdefghijklmnopqrstuvwxyz",
  numbers = "0123456789",
  symbols = "!@#$%^&*()-_=+[]{}|;:,.<>?/~",
  ambiguous = "0O1lI|`'\"~"
}

local function removeChars(sourceStr, charsToRemove)
  local removeMap = {}
  for c in charsToRemove:gmatch(".") do
    removeMap[c] = true
  end
  local out = {}
  for c in sourceStr:gmatch(".") do
    if not removeMap[c] then
      table.insert(out, c)
    end
  end
  return table.concat(out)
end

--------------------------------------------------------------------------------
-- Generation Algorithms
--------------------------------------------------------------------------------

obj.algorithms = {}

-- Algorithm: Random Charset
obj.algorithms.random = function(self, opts)
  opts = opts or {}
  local length = opts.length or self.password_length or 20
  local useUpper = opts.uppercase ~= false
  local useLower = opts.lowercase ~= false
  local useNumbers = opts.numbers ~= false
  local useSymbols = opts.symbols ~= false
  local customSymbols = opts.custom_symbols or CHARSETS.symbols
  local excludeAmbiguous = opts.exclude_ambiguous ~= false
  local sourceName = opts.random_source or self.random_source

  if opts.custom_charset and #opts.custom_charset > 0 then
    local charset = opts.custom_charset
    if excludeAmbiguous then
      charset = removeChars(charset, CHARSETS.ambiguous)
    end
    if #charset == 0 then charset = opts.custom_charset end
    local pwdChars = {}
    for i = 1, length do
      local idx = getRandomInt(sourceName, 1, #charset)
      table.insert(pwdChars, charset:sub(idx, idx))
    end
    return table.concat(pwdChars)
  end

  local u = CHARSETS.upper
  local l = CHARSETS.lower
  local n = CHARSETS.numbers
  local s = customSymbols

  if excludeAmbiguous then
    u = removeChars(u, CHARSETS.ambiguous)
    l = removeChars(l, CHARSETS.ambiguous)
    n = removeChars(n, CHARSETS.ambiguous)
    s = removeChars(s, CHARSETS.ambiguous)
  end

  local pools = {}
  local guaranteed = {}

  if useUpper and #u > 0 then
    table.insert(pools, u)
    local idx = getRandomInt(sourceName, 1, #u)
    table.insert(guaranteed, u:sub(idx, idx))
  end
  if useLower and #l > 0 then
    table.insert(pools, l)
    local idx = getRandomInt(sourceName, 1, #l)
    table.insert(guaranteed, l:sub(idx, idx))
  end
  if useNumbers and #n > 0 then
    table.insert(pools, n)
    local idx = getRandomInt(sourceName, 1, #n)
    table.insert(guaranteed, n:sub(idx, idx))
  end
  if useSymbols and #s > 0 then
    table.insert(pools, s)
    local idx = getRandomInt(sourceName, 1, #s)
    table.insert(guaranteed, s:sub(idx, idx))
  end

  if #pools == 0 then
    pools = { CHARSETS.lower }
  end

  local allChars = table.concat(pools)
  local result = {}

  for i = 1, math.min(#guaranteed, length) do
    table.insert(result, guaranteed[i])
  end

  for i = #result + 1, length do
    local idx = getRandomInt(sourceName, 1, #allChars)
    table.insert(result, allChars:sub(idx, idx))
  end

  shuffleTable(result, sourceName)
  return table.concat(result)
end

-- Algorithm: Authentic 5-Dice Diceware Passphrase
obj.algorithms.diceware = function(self, opts)
  opts = opts or {}
  local wordCount = opts.word_count or 5
  local separator = opts.separator or " "
  local capitalize = opts.capitalize or "none"
  local includeNumber = opts.include_number
  local includeSymbol = opts.include_symbol
  local sourceName = opts.random_source or self.random_source

  local words = {}
  for i = 1, wordCount do
    local word, _ = rollDiceWord(sourceName)
    if capitalize == "title" then
      word = word:sub(1, 1):upper() .. word:sub(2)
    elseif capitalize == "upper" then
      word = word:upper()
    elseif capitalize == "random" then
      if getRandomInt(sourceName, 0, 1) == 1 then
        word = word:sub(1, 1):upper() .. word:sub(2)
      end
    end
    table.insert(words, word)
  end

  if includeNumber then
    local num = tostring(getRandomInt(sourceName, 0, 99))
    local insertIdx = getRandomInt(sourceName, 1, #words)
    words[insertIdx] = words[insertIdx] .. num
  end

  if includeSymbol then
    local symPool = "!@#$%^&*"
    local sIdx = getRandomInt(sourceName, 1, #symPool)
    local sym = symPool:sub(sIdx, sIdx)
    local insertIdx = getRandomInt(sourceName, 1, #words)
    words[insertIdx] = words[insertIdx] .. sym
  end

  return table.concat(words, separator)
end

-- Algorithm: Passphrase / Diceware / XKCD
obj.algorithms.passphrase = function(self, opts)
  opts = opts or {}
  local wordCount = opts.word_count or self.word_count or 4
  local wordSource = opts.word_source or opts.source or "eff_diceware"
  local separator = opts.separator or "-"
  local capitalize = opts.capitalize or "title"
  local leetPos = opts.word_leet or self.word_leet or 0
  local includeNumber = opts.include_number
  local includeSymbol = opts.include_symbol
  local sourceName = opts.random_source or self.random_source

  local words = {}
  if type(wordSource) == "table" then
    words = wordSource
  elseif type(wordSource) == "string" then
    local srcFn = self.sources.wordlist[wordSource]
    if srcFn then
      words = srcFn()
    else
      words = load_wordlist_file(wordSource)
    end
  end

  if not words or #words == 0 then
    words = self.sources.wordlist.xkcd()
  end
  if not words or #words == 0 then
    words = { "apple", "banana", "cherry", "dragon", "eagle", "forest", "harbor", "island" }
  end

  local activeSep = separator
  if opts.separators or separator == "random" then
    local seps = opts.separators or { "-", "_", ".", "#", "$" }
    if type(seps) == "string" then
      local t = {}
      seps:gsub(".", function(c) table.insert(t, c) end)
      seps = t
    end
    activeSep = seps[getRandomInt(sourceName, 1, #seps)]
  end

  local leetChars = { a = "4", e = "3", l = "1", o = "0", s = "5", i = "!" }
  local function applyLeet(str)
    local out = {}
    for c in str:gmatch(".") do
      table.insert(out, leetChars[c:lower()] or c)
    end
    return table.concat(out)
  end

  local selected = {}
  for i = 1, wordCount do
    local word = words[getRandomInt(sourceName, 1, #words)] or "word"
    if capitalize == "title" or (type(self.word_uppercase) == "number" and i <= self.word_uppercase) then
      word = word:sub(1, 1):upper() .. word:sub(2)
    elseif capitalize == "upper" then
      word = word:upper()
    elseif capitalize == "lower" then
      word = word:lower()
    elseif capitalize == "random" then
      if getRandomInt(sourceName, 0, 1) == 1 then
        word = word:sub(1, 1):upper() .. word:sub(2)
      end
    end

    if i == leetPos then
      word = applyLeet(word)
    end
    table.insert(selected, word)
  end

  if includeNumber then
    local num = tostring(getRandomInt(sourceName, 0, 99))
    local insertIdx = getRandomInt(sourceName, 1, #selected)
    selected[insertIdx] = selected[insertIdx] .. num
  end

  if includeSymbol then
    local symPool = "!@#$%^&*"
    local sIdx = getRandomInt(sourceName, 1, #symPool)
    local sym = symPool:sub(sIdx, sIdx)
    local insertIdx = getRandomInt(sourceName, 1, #selected)
    selected[insertIdx] = selected[insertIdx] .. sym
  end

  return table.concat(selected, activeSep)
end

-- Backward compatibility alias
obj.algorithms.xkcd = obj.algorithms.passphrase

local function isWordListAlgo(algo)
  return algo == "diceware" or algo == "passphrase" or algo == "xkcd"
      or algo == "eff_large" or algo == "efflarge"
      or algo == "eff_short_v2" or algo == "effshortv2" or algo == "eff_short"
      or algo == "star_trek" or algo == "startrek" or algo == "star-trek"
      or algo == "star_wars" or algo == "starwars" or algo == "star-wars"
      or algo == "harry_potter" or algo == "harrypotter" or algo == "harry-potter"
end

local function makePassphraseAlgo(sourceName)
  return function(self, opts)
    opts = opts or {}
    local copyOpts = {}
    for k, v in pairs(opts) do copyOpts[k] = v end
    copyOpts.word_source = copyOpts.word_source or sourceName
    return self.algorithms.passphrase(self, copyOpts)
  end
end

obj.algorithms.eff_large = makePassphraseAlgo("eff_large")
obj.algorithms.efflarge = obj.algorithms.eff_large
obj.algorithms.eff_short_v2 = makePassphraseAlgo("eff_short_v2")
obj.algorithms.effshortv2 = obj.algorithms.eff_short_v2
obj.algorithms.eff_short = obj.algorithms.eff_short_v2
obj.algorithms.star_trek = makePassphraseAlgo("star_trek")
obj.algorithms.startrek = obj.algorithms.star_trek
obj.algorithms["star-trek"] = obj.algorithms.star_trek
obj.algorithms.star_wars = makePassphraseAlgo("star_wars")
obj.algorithms.starwars = obj.algorithms.star_wars
obj.algorithms["star-wars"] = obj.algorithms.star_wars
obj.algorithms.harry_potter = makePassphraseAlgo("harry_potter")
obj.algorithms.harrypotter = obj.algorithms.harry_potter
obj.algorithms["harry-potter"] = obj.algorithms.harry_potter

-- Algorithm: Numeric PIN
obj.algorithms.pin = function(self, opts)
  opts = opts or {}
  local length = opts.length or 6
  local allowRepeats = opts.allow_repeats ~= false
  local allowSequences = opts.allow_sequences == true
  local sourceName = opts.random_source or self.random_source

  for attempt = 1, 100 do
    local digits = {}
    for i = 1, length do
      local d
      if not allowRepeats and i > 1 then
        repeat
          d = getRandomInt(sourceName, 0, 9)
        until d ~= digits[i - 1]
      else
        d = getRandomInt(sourceName, 0, 9)
      end
      table.insert(digits, d)
    end

    local pin = table.concat(digits)

    if not allowSequences and length >= 3 then
      local isAscending = true
      local isDescending = true
      local isAllSame = true
      for i = 2, length do
        if digits[i] ~= digits[i - 1] + 1 then isAscending = false end
        if digits[i] ~= digits[i - 1] - 1 then isDescending = false end
        if digits[i] ~= digits[1] then isAllSame = false end
      end
      if not (isAscending or isDescending or isAllSame) then
        return pin
      end
    else
      return pin
    end
  end

  return tostring(getRandomInt(sourceName, 100000, 999999))
end

-- Algorithm: Pattern Mask
obj.algorithms.pattern = function(self, opts)
  opts = opts or {}
  local mask = opts.pattern or opts.mask or "Ulll-dddd-SSSS"
  local sourceName = opts.random_source or self.random_source

  local vowels = "aeiou"
  local consonants = "bcdfghjklmnpqrstvwxyz"
  local hexChars = "0123456789abcdef"

  local result = {}
  local i = 1
  local len = #mask

  while i <= len do
    local c = mask:sub(i, i)
    if c == "\\" and i < len then
      i = i + 1
      table.insert(result, mask:sub(i, i))
    elseif c == "U" or (c == "?" and mask:sub(i + 1, i + 1) == "u") then
      if c == "?" then i = i + 1 end
      local idx = getRandomInt(sourceName, 1, 26)
      table.insert(result, CHARSETS.upper:sub(idx, idx))
    elseif c == "l" or (c == "?" and mask:sub(i + 1, i + 1) == "l") then
      if c == "?" then i = i + 1 end
      local idx = getRandomInt(sourceName, 1, 26)
      table.insert(result, CHARSETS.lower:sub(idx, idx))
    elseif c == "d" or (c == "?" and mask:sub(i + 1, i + 1) == "d") then
      if c == "?" then i = i + 1 end
      local idx = getRandomInt(sourceName, 1, 10)
      table.insert(result, CHARSETS.numbers:sub(idx, idx))
    elseif c == "s" or c == "S" or (c == "?" and mask:sub(i + 1, i + 1) == "s") then
      if c == "?" then i = i + 1 end
      local syms = opts.custom_symbols or CHARSETS.symbols
      local idx = getRandomInt(sourceName, 1, #syms)
      table.insert(result, syms:sub(idx, idx))
    elseif c == "a" or c == "A" or (c == "?" and mask:sub(i + 1, i + 1) == "a") then
      if c == "?" then i = i + 1 end
      local pool = CHARSETS.upper .. CHARSETS.lower .. CHARSETS.numbers
      local idx = getRandomInt(sourceName, 1, #pool)
      table.insert(result, pool:sub(idx, idx))
    elseif c == "x" or (c == "?" and mask:sub(i + 1, i + 1) == "x") then
      if c == "?" then i = i + 1 end
      local idx = getRandomInt(sourceName, 1, #hexChars)
      table.insert(result, hexChars:sub(idx, idx))
    elseif c == "X" or (c == "?" and mask:sub(i + 1, i + 1) == "X") then
      if c == "?" then i = i + 1 end
      local idx = getRandomInt(sourceName, 1, #hexChars)
      table.insert(result, hexChars:sub(idx, idx):upper())
    elseif c == "v" or c == "V" then
      local idx = getRandomInt(sourceName, 1, #vowels)
      local ch = vowels:sub(idx, idx)
      table.insert(result, c == "V" and ch:upper() or ch)
    elseif c == "c" or c == "C" then
      local idx = getRandomInt(sourceName, 1, #consonants)
      local ch = consonants:sub(idx, idx)
      table.insert(result, c == "C" and ch:upper() or ch)
    else
      table.insert(result, c)
    end
    i = i + 1
  end

  return table.concat(result)
end

-- Algorithm: Pronounceable Syllables
obj.algorithms.pronounceable = function(self, opts)
  opts = opts or {}
  local length = opts.length or 12
  local sourceName = opts.random_source or self.random_source
  local consonants = { "b", "c", "d", "f", "g", "h", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "z" }
  local vowels = { "a", "e", "i", "o", "u" }

  local parts = {}
  local currentLen = 0

  while currentLen < length do
    local c = consonants[getRandomInt(sourceName, 1, #consonants)]
    local v = vowels[getRandomInt(sourceName, 1, #vowels)]
    local syllable = c .. v
    if currentLen + #syllable + 1 <= length and getRandomInt(sourceName, 1, 3) == 1 then
      local cEnd = consonants[getRandomInt(sourceName, 1, #consonants)]
      syllable = syllable .. cEnd
    end

    if currentLen == 0 and opts.capitalize ~= false then
      syllable = syllable:sub(1, 1):upper() .. syllable:sub(2)
    end

    table.insert(parts, syllable)
    currentLen = currentLen + #syllable
    if currentLen < length - 2 and getRandomInt(sourceName, 1, 2) == 1 then
      table.insert(parts, "-")
      currentLen = currentLen + 1
    end
  end

  local res = table.concat(parts)
  if opts.include_number ~= false then
    local num = tostring(getRandomInt(sourceName, 0, 9))
    res = res:sub(1, math.max(1, length - 1)) .. num
  else
    res = res:sub(1, length)
  end

  return res
end

-- Algorithm: Cryptographic Token / Hash
obj.algorithms.token = function(self, opts)
  opts = opts or {}
  local format = opts.format or "hex"
  local length = opts.length or 32
  local sourceName = opts.random_source or self.random_source

  if format == "uuid" or format == "uuid4" then
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    local hexAlphabet = "0123456789abcdef"
    local yAlphabet = "89ab"
    local out = {}
    for c in template:gmatch(".") do
      if c == "x" then
        local idx = getRandomInt(sourceName, 1, 16)
        table.insert(out, hexAlphabet:sub(idx, idx))
      elseif c == "y" then
        local idx = getRandomInt(sourceName, 1, 4)
        table.insert(out, yAlphabet:sub(idx, idx))
      else
        table.insert(out, c)
      end
    end
    return table.concat(out)
  elseif format == "hex" then
    local byteCount = math.ceil(length / 2)
    local out = {}
    for i = 1, byteCount do
      local b = getRandomInt(sourceName, 0, 255)
      table.insert(out, string.format("%02x", b))
    end
    return table.concat(out):sub(1, length)
  elseif format == "base64" or format == "base64url" then
    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" .. (format == "base64url" and "-_" or "+/")
    local out = {}
    for i = 1, length do
      local idx = getRandomInt(sourceName, 1, 64)
      table.insert(out, b64chars:sub(idx, idx))
    end
    return table.concat(out)
  end

  return self.algorithms.random(self, { length = length, symbols = false })
end

-- Legacy default generator function (MD5 hash of math.random)
local function legacy_default_generator(self)
  local hashfn = nil
  if has_hs and hs.hash and hs.hash.MD5 then
    hashfn = hs.hash.MD5
  else
    hashfn = function(val)
      return string.format("%08x%08x%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
    end
  end
  local pwd = hashfn(tostring(math.random()))
  return string.sub(pwd, 1, self.password_length or 20)
end

--------------------------------------------------------------------------------
-- Default Configuration & Configurable Items
--------------------------------------------------------------------------------

--- PasswordGenerator.random_source
--- Variable
--- Randomness source to use for password generation.
--- Possible values: `"csprng"` (default, uses `/dev/urandom`), `"math_random"`.
obj.random_source = getSetting("random_source", "csprng")

--- PasswordGenerator.default_item
--- Variable
--- The default item ID to generate when invoking `copyPassword()` or `pastePassword()`.
--- Default is `"strong"`.
obj.default_item = getSetting("default_item", "strong")

--- PasswordGenerator.show_in_menubar
--- Variable
--- Whether to display a menubar dropdown item. Default is `true`.
obj.show_in_menubar = getSetting("show_in_menubar", true)

--- PasswordGenerator.interactive_menu
--- Variable
--- Whether clicking the menubar icon displays the rich interactive segmented-bar dropdown menu.
--- Defaults to `true`. When set to `false`, falls back to a standard macOS menu.
obj.interactive_menu = getSetting("interactive_menu", true)

--- PasswordGenerator.clipboard_clear_timeout
--- Variable
--- Seconds after which the copied password will be automatically cleared from the clipboard.
--- Set to `0` or `nil` to disable auto-clearing. Default is `45`.
obj.clipboard_clear_timeout = getSetting("clipboard_clear_timeout", 45)

--- PasswordGenerator.conceal_clipboard
--- Variable
--- If `true`, marks the clipboard entry as concealed/transient to prevent clipboard managers from storing it. Default is `true`.
obj.conceal_clipboard = getSetting("conceal_clipboard", true)

--- PasswordGenerator.show_notifications
--- Variable
--- Whether to show a notification when a password is generated. Default is `true`.
obj.show_notifications = getSetting("show_notifications", true)

--- PasswordGenerator.interactive_hud_width
--- Variable
--- Width of the interactive menu dropdown window in points. Default is `380`.
obj.interactive_hud_width = getSetting("interactive_hud_width", 380)

-- Legacy configuration variables (preserved for 100% backward compatibility)
--- PasswordGenerator.password_style
--- Variable
--- Legacy style for the generated password: `"default"` or `"xkcd"`.
obj.password_style = getSetting("password_style", "default")

--- PasswordGenerator.password_generator_function
--- Variable
--- Explicit function used to generate passwords; if set, overrides style/item defaults.
obj.password_generator_function = nil

--- PasswordGenerator.password_length
--- Variable
--- Length of generated passwords. Default is `20`.
obj.password_length = getSetting("password_length", 20)

--- PasswordGenerator.word_count
--- Variable
--- Number of words in generated passwords. Default is `4`.
obj.word_count = getSetting("word_count", 4)

--- PasswordGenerator.word_leet
--- Variable
--- Word index to apply leet transformation to. Default is `0`.
obj.word_leet = getSetting("word_leet", 0)

--- PasswordGenerator.word_separators
--- Variable
--- Separator characters between words. Default is `" _-,$"`.
obj.word_separators = getSetting("word_separators", " _-,$")

--- PasswordGenerator.word_uppercase
--- Variable
--- Number of words to uppercase the first letter. Default is `1`.
obj.word_uppercase = getSetting("word_uppercase", 1)

-- Internal items storage
obj.items = {}
obj.itemsById = {}

local DEFAULT_ITEMS = {
  {
    id = "strong",
    title = "Strong Password",
    algorithm = "random",
    length = 20,
    uppercase = true,
    lowercase = true,
    numbers = true,
    symbols = true,
    exclude_ambiguous = true
  },
  {
    id = "diceware",
    title = "Diceware",
    algorithm = "diceware",
    word_count = 5,
    separator = " ",
    capitalize = "none"
  },
  {
    id = "passphrase",
    title = "Memorable Passphrase",
    algorithm = "passphrase",
    word_count = 4,
    word_source = "eff_diceware",
    separator = "-",
    capitalize = "title"
  },
  {
    id = "pin",
    title = "PIN Code",
    algorithm = "pin",
    length = 6,
    allow_repeats = true,
    allow_sequences = false
  },
  {
    id = "alphanumeric",
    title = "Alphanumeric",
    algorithm = "random",
    length = 16,
    uppercase = true,
    lowercase = true,
    numbers = true,
    symbols = false,
    exclude_ambiguous = true
  },
  {
    id = "hex_token",
    title = "Hex Token",
    algorithm = "token",
    format = "hex",
    length = 32
  },
  {
    id = "pronounceable",
    title = "Pronounceable",
    algorithm = "pronounceable",
    length = 12,
    include_number = true
  },
  {
    id = "eff_large",
    title = "EFF Large Passphrase",
    algorithm = "passphrase",
    word_source = "eff_large",
    word_count = 5,
    separator = " ",
    capitalize = "none"
  },
  {
    id = "eff_short_v2",
    title = "EFF Short v2 Passphrase",
    algorithm = "passphrase",
    word_source = "eff_short_v2",
    word_count = 5,
    separator = " ",
    capitalize = "none"
  },
  {
    id = "star_trek",
    title = "Star Trek Passphrase",
    algorithm = "passphrase",
    word_source = "star_trek",
    word_count = 4,
    separator = "-",
    capitalize = "title"
  },
  {
    id = "star_wars",
    title = "Star Wars Passphrase",
    algorithm = "passphrase",
    word_source = "star_wars",
    word_count = 4,
    separator = "-",
    capitalize = "title"
  },
  {
    id = "harry_potter",
    title = "Harry Potter Passphrase",
    algorithm = "passphrase",
    word_source = "harry_potter",
    word_count = 4,
    separator = "-",
    capitalize = "title"
  }
}

--- PasswordGenerator:addItem(itemSpec)
--- Method
--- Adds or updates a configured password item preset.
---
--- Parameters:
---  * itemSpec - A table containing item configuration:
---    * `id` - String unique identifier for the item (required)
---    * `title` - Human-readable label displayed in menus (required)
---    * `algorithm` - Name of algorithm: `"random"`, `"diceware"`, `"passphrase"`, `"pin"`, `"pattern"`, `"pronounceable"`, `"token"`, or custom (default: `"random"`)
---    * `hotkey` - Optional table containing modifier keys and key character for hotkey binding
---    * Algorithm options (e.g. `length`, `separator`, `symbols`, `word_count`, `format`, `pattern`, etc.)
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:addItem(itemSpec)
  if not itemSpec or type(itemSpec) ~= "table" or not itemSpec.id then
    print(self.name .. ": addItem requires a table with an 'id'")
    return self
  end

  local item = {}
  for k, v in pairs(itemSpec) do item[k] = v end
  item.algorithm = item.algorithm or "random"
  item.title = item.title or item.id

  if self.itemsById[item.id] then
    for idx, existing in ipairs(self.items) do
      if existing.id == item.id then
        self.items[idx] = item
        break
      end
    end
  else
    table.insert(self.items, item)
  end

  self.itemsById[item.id] = item
  if self._updateMenubar then self:_updateMenubar() end
  return self
end

--- PasswordGenerator:removeItem(id)
--- Method
--- Removes a configured password item preset by ID.
---
--- Parameters:
---  * id - String identifier of the item to remove
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:removeItem(id)
  if not id then return self end
  self.itemsById[id] = nil
  for idx, item in ipairs(self.items) do
    if item.id == id then
      table.remove(self.items, idx)
      break
    end
  end
  if self._updateMenubar then self:_updateMenubar() end
  return self
end

--- PasswordGenerator:getItem(id)
--- Method
--- Retrieves a configured item preset definition by ID.
---
--- Parameters:
---  * id - String identifier of the item
---
--- Returns:
---  * The item table, or nil if not found
function obj:getItem(id)
  return self.itemsById[id]
end

--- PasswordGenerator:listItems()
--- Method
--- Returns an array of all configured item presets in order.
---
--- Parameters:
---  * None
---
--- Returns:
---  * Table array of item definitions
function obj:listItems()
  return self.items
end

--- PasswordGenerator:registerAlgorithm(name, generatorFn)
--- Method
--- Registers a new custom password generation algorithm.
---
--- Parameters:
---  * name - String identifier for the algorithm
---  * generatorFn - Function `fn(self, opts)` that returns the generated password string
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:registerAlgorithm(name, generatorFn)
  if type(name) == "string" and type(generatorFn) == "function" then
    self.algorithms[name] = generatorFn
  end
  return self
end

--- PasswordGenerator:registerWordSource(name, loaderOrTable)
--- Method
--- Registers a new wordlist source for passphrase generation.
---
--- Parameters:
---  * name - String identifier for the word source
---  * loaderOrTable - Function returning a table of words, or a table of words
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:registerWordSource(name, loaderOrTable)
  if type(name) == "string" then
    if type(loaderOrTable) == "function" then
      self.sources.wordlist[name] = loaderOrTable
    elseif type(loaderOrTable) == "table" then
      self.sources.wordlist[name] = function() return loaderOrTable end
    end
  end
  return self
end

--- PasswordGenerator:configure(options)
--- Method
--- Configures the PasswordGenerator with settings and preset items.
---
--- Parameters:
---  * options - Table of configuration options:
---    * `default_item` - Default item ID (e.g. "strong", "diceware", "passphrase")
---    * `show_in_menubar` - Boolean whether to display menubar icon
---    * `interactive_menu` - Boolean whether menubar clicks open the rich interactive dropdown
---    * `clipboard_clear_timeout` - Auto-clear timeout in seconds (0 to disable)
---    * `conceal_clipboard` - Boolean whether to mark pasteboard transient/concealed
---    * `show_notifications` - Boolean whether to show notification alerts
---    * `random_source` - Entropy source ("csprng" or "math_random")
---    * `items` - Array of item specifications to add or replace
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:configure(options)
  options = options or {}
  if options.default_item ~= nil then self.default_item = options.default_item end
  if options.show_in_menubar ~= nil then self.show_in_menubar = options.show_in_menubar end
  if options.interactive_menu ~= nil then self.interactive_menu = options.interactive_menu end
  if options.clipboard_clear_timeout ~= nil then self.clipboard_clear_timeout = options.clipboard_clear_timeout end
  if options.conceal_clipboard ~= nil then self.conceal_clipboard = options.conceal_clipboard end
  if options.show_notifications ~= nil then self.show_notifications = options.show_notifications end
  if options.random_source ~= nil then self.random_source = options.random_source end
  if options.interactive_hud_width ~= nil then self.interactive_hud_width = options.interactive_hud_width end

  if options.items and type(options.items) == "table" then
    self.items = {}
    self.itemsById = {}
    for _, it in ipairs(options.items) do
      self:addItem(it)
    end
  end

  if self.show_in_menubar then
    self:start()
  else
    self:stop()
  end

  return self
end

-- Initialize default items
for _, it in ipairs(DEFAULT_ITEMS) do
  obj:addItem(it)
end

--------------------------------------------------------------------------------
-- Generation Core
--------------------------------------------------------------------------------

--- PasswordGenerator:generate([itemOrOptions])
--- Method
--- Generates a password string based on an item ID or an options table.
---
--- Parameters:
---  * itemOrOptions - Optional string (item ID) or table with options. If nil, uses `default_item` (or legacy configuration).
---
--- Returns:
---  * The generated password string
function obj:generate(itemOrOptions)
  if type(self.password_generator_function) == "function" then
    return self.password_generator_function(self)
  end

  if itemOrOptions == nil and self.password_style and self.password_style ~= "default" then
    if self.password_style == "xkcd" then
      return self.algorithms.passphrase(self, {
        word_count = self.word_count,
        word_leet = self.word_leet,
        separators = self.word_separators,
        word_uppercase = self.word_uppercase,
        source = "xkcd"
      })
    end
  end

  local opts = {}
  local algoName = "random"

  if type(itemOrOptions) == "string" then
    local item = self:getItem(itemOrOptions)
    if item then
      opts = item
      algoName = item.algorithm or "random"
    else
      local defItem = self:getItem(self.default_item)
      if defItem then
        opts = defItem
        algoName = defItem.algorithm or "random"
      end
    end
  elseif type(itemOrOptions) == "table" then
    opts = itemOrOptions
    algoName = opts.algorithm or "random"
  else
    local defItem = self:getItem(self.default_item)
    if defItem then
      opts = defItem
      algoName = defItem.algorithm or "random"
    elseif self.password_style == "default" and not self.default_item then
      return legacy_default_generator(self)
    end
  end

  local algoFn = self.algorithms[algoName] or self.algorithms.random
  return algoFn(self, opts)
end

--- PasswordGenerator:getPasswordGenerator()
--- Method
--- Legacy helper returning the generator function.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A function `fn(self)` that generates a password
function obj:getPasswordGenerator()
  if type(self.password_generator_function) == "function" then
    return self.password_generator_function
  end
  return function(s)
    return s:generate()
  end
end

--------------------------------------------------------------------------------
-- Clipboard & Notifications
--------------------------------------------------------------------------------

local activeClearTimer = nil

local function sanitizeClipboard(pwd)
  if not has_hs or not hs.pasteboard then return end
  local current = hs.pasteboard.getContents()
  if current == pwd then
    hs.pasteboard.clearContents()
    if obj.show_notifications and hs.alert then
      hs.alert.show("PasswordGenerator: Clipboard sanitized")
    end
  end
end

--- PasswordGenerator:calculateEntropy([itemOrOptions], [val])
--- Method
--- Calculates the Shannon entropy in bits for a given password configuration and length/count.
---
--- Parameters:
---  * itemOrOptions - Optional string (item ID) or table with options. If nil, uses default item.
---  * val - Optional integer length or word count override.
---
--- Returns:
---  * A number representing bits of entropy
function obj:calculateEntropy(itemOrOptions, val)
  local item = nil
  if type(itemOrOptions) == "string" then
    item = self:getItem(itemOrOptions)
  elseif type(itemOrOptions) == "table" then
    if itemOrOptions.algorithm then
      item = itemOrOptions
    elseif itemOrOptions.id then
      item = self:getItem(itemOrOptions.id) or itemOrOptions
    else
      item = itemOrOptions
    end
  else
    item = self:getItem(self.default_item) or (self.items and self.items[1])
  end

  local algo = (item and item.algorithm) or "random"

  if algo == "diceware" then
    local wc = val or (item and item.word_count) or self.word_count or 5
    return wc * 12.9248

  elseif isWordListAlgo(algo) then
    local wc = val or (item and item.word_count) or self.word_count or 4
    local src = (item and (item.word_source or item.source)) or (algo ~= "passphrase" and algo ~= "xkcd" and algo) or "eff_diceware"
    local pool = 7776
    if src == "eff_short" or src == "eff_words" or src == "eff_short_v2" or src == "effshortv2" then
      pool = 1296
    elseif src == "eff_large" or src == "efflarge" or src == "diceware" or src == "eff_diceware" then
      pool = 7776
    elseif src == "star_trek" or src == "startrek" or src == "star-trek"
        or src == "star_wars" or src == "starwars" or src == "star-wars"
        or src == "harry_potter" or src == "harrypotter" or src == "harry-potter" then
      pool = 4000
    elseif self.sources and self.sources.wordlist and self.sources.wordlist[src] then
      local wlist = self.sources.wordlist[src]()
      if wlist and #wlist > 0 then pool = #wlist end
    elseif cached_wordlists and cached_wordlists[src] and #cached_wordlists[src] > 0 then
      pool = #cached_wordlists[src]
    end
    return wc * (math.log(pool) / math.log(2))

  elseif algo == "pin" then
    local len = val or (item and item.length) or 6
    return len * (math.log(10) / math.log(2))

  elseif algo == "token" then
    local len = val or (item and item.length) or 32
    local fmt = (item and item.format) or "hex"
    if fmt == "base64" or fmt == "urlsafe" then
      return len * 6.0
    elseif fmt == "base32" then
      return len * 5.0
    else
      return len * 4.0
    end

  elseif algo == "pronounceable" then
    local len = val or (item and item.length) or 12
    local bits = len * (math.log(100) / math.log(2) / 2)
    if item and item.include_number then
      bits = bits + (math.log(10) / math.log(2))
    end
    return bits

  elseif algo == "pattern" then
    local pat = (item and item.pattern) or "LLdd-uudd"
    local bits = 0
    for i = 1, #pat do
      local ch = pat:sub(i, i)
      if ch == "d" then bits = bits + 3.3219
      elseif ch == "l" or ch == "u" or ch == "L" or ch == "U" then bits = bits + 4.7004
      elseif ch == "s" then bits = bits + 5.0
      elseif ch == "a" or ch == "A" then bits = bits + 5.9542
      end
    end
    return bits

  else -- random
    local len = val or (item and item.length) or self.password_length or 20
    local pool = 0
    local lower = (item == nil or item.lowercase ~= false)
    local upper = (item == nil or item.uppercase ~= false)
    local nums = (item == nil or item.numbers ~= false)
    local syms = (item and item.symbols ~= nil and item.symbols ~= false)

    if lower then pool = pool + 26 end
    if upper then pool = pool + 26 end
    if nums then pool = pool + 10 end
    if syms then
      if type(item.symbols) == "string" and #item.symbols > 0 then
        pool = pool + #item.symbols
      else
        pool = pool + 32
      end
    end

    if item and item.exclude_ambiguous then
      local amb = 0
      if lower then amb = amb + 1 end
      if upper then amb = amb + 2 end
      if nums then amb = amb + 2 end
      if syms then amb = amb + 9 end
      pool = math.max(2, pool - amb)
    end

    if pool < 2 then pool = 62 end
    return len * (math.log(pool) / math.log(2))
  end
end

--- PasswordGenerator:copyPassword([itemOrOptions])
--- Method
--- Generates a password and copies it to the system clipboard.
---
--- Parameters:
---  * itemOrOptions - Optional string (item ID) or table with options. If nil, uses default item.
---
--- Returns:
---  * The generated password string
function obj:copyPassword(itemOrOptions)
  local pwd = self:generate(itemOrOptions)

  if has_hs and hs.pasteboard then
    if self.conceal_clipboard and hs.pasteboard.writeObjects then
      hs.pasteboard.setContents(pwd)
    else
      hs.pasteboard.setContents(pwd)
    end
  end

  -- Auto-clear timer
  if self.clipboard_clear_timeout and self.clipboard_clear_timeout > 0 and has_hs and hs.timer then
    if activeClearTimer then
      activeClearTimer:stop()
      activeClearTimer = nil
    end
    activeClearTimer = hs.timer.doAfter(self.clipboard_clear_timeout, function()
      sanitizeClipboard(pwd)
    end)
  end

  if self.show_notifications and has_hs and hs.alert then
    local label = "Password"
    local opts = nil
    if type(itemOrOptions) == "string" then
      local it = self:getItem(itemOrOptions)
      if it then
        opts = it
        if it.title then label = it.title end
      end
    elseif type(itemOrOptions) == "table" then
      opts = itemOrOptions
      if itemOrOptions.title then
        label = itemOrOptions.title
      elseif itemOrOptions.id then
        local it = self:getItem(itemOrOptions.id)
        if it and it.title then label = it.title end
      end
    else
      local defIt = self:getItem(self.default_item) or (self.items and self.items[1])
      if defIt then
        opts = defIt
        if defIt.title then label = defIt.title end
      end
    end

    -- Clean any static count text from the title (e.g. "(20 chars)", "(5 words)", "(6 digits)")
    local cleanLabel = label:gsub("%s*%([^)]*chars?%)", "")
                            :gsub("%s*%([^)]*words?%)", "")
                            :gsub("%s*%([^)]*digits?%)", "")
                            :match("^%s*(.-)%s*$")
    if not cleanLabel or cleanLabel == "" then cleanLabel = "Password" end

    -- Determine algorithm from opts, opts.id, or fallback
    local algo = (opts and opts.algorithm)
    if not algo and opts and opts.id then
      local it = self:getItem(opts.id)
      if it and it.algorithm then algo = it.algorithm end
    end
    if not algo then
      local def = self:getItem(self.default_item) or (self.items and self.items[1])
      if def and def.algorithm then algo = def.algorithm end
    end
    algo = algo or "random"

    local lengthDesc = ""
    if isWordListAlgo(algo) then
      local wc = (opts and opts.word_count)
      if not wc and opts and opts.id then
        local it = self:getItem(opts.id)
        if it and it.word_count then wc = it.word_count end
      end
      wc = wc or self.word_count or 5
      lengthDesc = string.format("%d words", wc)
    elseif algo == "pin" then
      local len = (opts and opts.length)
      if not len and opts and opts.id then
        local it = self:getItem(opts.id)
        if it and it.length then len = it.length end
      end
      len = len or #pwd
      lengthDesc = string.format("%d digits", len)
    else
      local len = (opts and opts.length)
      if not len and opts and opts.id then
        local it = self:getItem(opts.id)
        if it and it.length then len = it.length end
      end
      len = len or #pwd
      lengthDesc = string.format("%d chars", len)
    end

    hs.alert.show(string.format("%s (%s) copied to clipboard", cleanLabel, lengthDesc))
  end

  return pwd
end

--- PasswordGenerator:pastePassword([itemOrOptions])
--- Method
--- Generates a password and types it into the active application.
---
--- Parameters:
---  * itemOrOptions - Optional string (item ID) or table with options. If nil, uses default item.
---
--- Returns:
---  * The generated password string
function obj:pastePassword(itemOrOptions)
  local pwd = self:generate(itemOrOptions)
  if has_hs and hs.eventtap and hs.eventtap.keyStrokes then
    hs.eventtap.keyStrokes(pwd)
  end
  return pwd
end

--------------------------------------------------------------------------------
-- Interactive Menubar Dropdown Menu
--------------------------------------------------------------------------------

obj.interactiveCanvas = nil
obj.interactiveClickTap = nil
obj.interactiveKeyTap = nil
obj.interactiveState = {
  activeItemIndex = 1,
  currentLength = nil,
  previewPassword = "",
  hoveredSegment = nil,
  hoveredPresetIndex = nil
}

local DEFAULT_SLIDER_COLOR = { red = 0.65, green = 0.80, blue = 1.0, alpha = 1.0 }

local function getItemSliderSpec(item)
  local algo = (item and item.algorithm) or "random"
  local sliderColor = (item and item.slider_color) or obj.slider_color or DEFAULT_SLIDER_COLOR

  if isWordListAlgo(algo) then
    return {
      type = "words",
      min = 3,
      max = 10,
      step = 1,
      defaultVal = (item and item.word_count) or 5,
      color = sliderColor,
      formatLabel = function(val)
        local ent = obj:calculateEntropy(item, val)
        return string.format("%d words (~%.1f bits entropy)", val, ent)
      end,
      applyVal = function(opts, val) opts.word_count = val end
    }
  elseif algo == "pin" then
    return {
      type = "digits",
      min = 4,
      max = 16,
      step = 1,
      defaultVal = (item and item.length) or 6,
      color = sliderColor,
      formatLabel = function(val)
        local ent = obj:calculateEntropy(item, val)
        return string.format("%d digits (~%.1f bits entropy)", val, ent)
      end,
      applyVal = function(opts, val) opts.length = val end
    }
  elseif algo == "token" then
    return {
      type = "chars",
      min = 16,
      max = 64,
      step = 4,
      defaultVal = (item and item.length) or 32,
      color = sliderColor,
      formatLabel = function(val)
        local ent = obj:calculateEntropy(item, val)
        return string.format("%d chars (~%.1f bits entropy)", val, ent)
      end,
      applyVal = function(opts, val) opts.length = val end
    }
  else
    return {
      type = "chars",
      min = 8,
      max = 40,
      step = 2,
      defaultVal = (item and item.length) or 20,
      color = sliderColor,
      formatLabel = function(val)
        local ent = obj:calculateEntropy(item, val)
        return string.format("%d chars (~%.1f bits entropy)", val, ent)
      end,
      applyVal = function(opts, val) opts.length = val end
    }
  end
end

function obj:_getInteractiveItemOpts(overrideLen)
  if not self.items[self.interactiveState.activeItemIndex] then
    self.interactiveState.activeItemIndex = 1
  end
  local item = self.items[self.interactiveState.activeItemIndex] or self:getItem(self.default_item) or self.items[1]
  local opts = {}
  if item then
    for k, v in pairs(item) do opts[k] = v end
  end
  local spec = getItemSliderSpec(item)
  local val = overrideLen or self.interactiveState.currentLength or spec.defaultVal
  if val < spec.min then val = spec.min end
  if val > spec.max then val = spec.max end
  spec.applyVal(opts, val)
  return opts, item, spec
end

function obj:_getInteractiveMenuDimensions()
  local W = self.interactive_hud_width or 380
  local itemCount = #self.items
  local H = 155 + (itemCount * 28) + 36
  return W, H
end

function obj:_renderInteractiveMenu()
  local c = self.interactiveCanvas
  if not c then return end

  local W, H = self:_getInteractiveMenuDimensions()
  local barX = 16
  local barY = 58
  local barW = W - 32
  local barH = 20

  local opts, item, spec = self:_getInteractiveItemOpts()
  local currentVal = self.interactiveState.currentLength or spec.defaultVal
  local segs = math.floor((spec.max - spec.min) / spec.step) + 1
  local gap = 2
  local segW = (barW - gap * (segs - 1)) / segs
  local filled = math.floor((currentVal - spec.min) / spec.step) + 1
  if filled < 1 then filled = 1 end
  if filled > segs then filled = segs end

  local elements = {}

  -- 1. Main Background Panel (macOS Dark Menu styling with shadow border)
  table.insert(elements, {
    type = "rectangle",
    action = "strokeAndFill",
    fillColor = { red = 0.12, green = 0.13, blue = 0.18, alpha = 0.97 },
    strokeColor = { red = 0.30, green = 0.34, blue = 0.42, alpha = 0.85 },
    strokeWidth = 1,
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
    frame = { x = 0, y = 0, w = W, h = H }
  })

  -- 2. Header Bar: Active Preset Switcher
  table.insert(elements, {
    id = "btn_prev",
    type = "text",
    text = "◀",
    textColor = { white = 0.75 },
    textSize = 13,
    textAlignment = "center",
    frame = { x = 12, y = 12, w = 22, h = 20 },
    trackMouseDown = true
  })

  table.insert(elements, {
    id = "title_cycle",
    type = "text",
    text = (item and item.title) or "Password Generator",
    textColor = { white = 0.98 },
    textSize = 14,
    textAlignment = "center",
    frame = { x = 36, y = 12, w = W - 72, h = 20 },
    trackMouseDown = true
  })

  table.insert(elements, {
    id = "btn_next",
    type = "text",
    text = "▶",
    textColor = { white = 0.75 },
    textSize = 13,
    textAlignment = "center",
    frame = { x = W - 34, y = 12, w = 22, h = 20 },
    trackMouseDown = true
  })

  -- 3. Length / Word count readout
  table.insert(elements, {
    type = "text",
    text = spec.formatLabel(currentVal),
    textColor = { red = 0.78, green = 0.82, blue = 0.92, alpha = 1.0 },
    textSize = 12,
    textAlignment = "left",
    frame = { x = barX, y = 38, w = barW, h = 16 }
  })

  -- 4. Segmented Bar (Discrete vertical slices matching user image)
  for s = 1, segs do
    local sx = barX + (s - 1) * (segW + gap)
    -- Inactive segment track (dark slate)
    table.insert(elements, {
      type = "rectangle",
      action = "fill",
      fillColor = { red = 0.28, green = 0.30, blue = 0.36, alpha = 0.95 },
      frame = { x = sx, y = barY, w = segW, h = barH },
      roundedRectRadii = { xRadius = 2, yRadius = 2 }
    })
    -- Active segment fill (light pastel blue or soft sage green)
    if s <= filled then
      table.insert(elements, {
        type = "rectangle",
        action = "fill",
        fillColor = spec.color,
        frame = { x = sx, y = barY, w = segW, h = barH },
        roundedRectRadii = { xRadius = 2, yRadius = 2 }
      })
    end
  end

  -- Hit-tracking overlay for mouse hover across the bar
  table.insert(elements, {
    id = "slider_bar",
    type = "rectangle",
    action = "fill",
    fillColor = { alpha = 0.001 },
    frame = { x = barX, y = barY, w = barW, h = barH },
    trackMouseMove = true,
    trackMouseEnterExit = true,
    trackMouseDown = true
  })

  -- 5. Monospace Live Preview Box
  table.insert(elements, {
    id = "btn_preview_click",
    type = "rectangle",
    action = "strokeAndFill",
    fillColor = { red = 0.07, green = 0.08, blue = 0.11, alpha = 0.90 },
    strokeColor = { red = 0.22, green = 0.25, blue = 0.33, alpha = 0.7 },
    strokeWidth = 1,
    roundedRectRadii = { xRadius = 5, yRadius = 5 },
    frame = { x = barX, y = 86, w = barW, h = 36 },
    trackMouseDown = true
  })

  table.insert(elements, {
    id = "btn_preview_click",
    type = "text",
    text = self.interactiveState.previewPassword or "...",
    textColor = { red = 0.92, green = 0.95, blue = 1.0, alpha = 1.0 },
    textSize = 12,
    textFont = "Menlo",
    textAlignment = "center",
    frame = { x = barX + 4, y = 94, w = barW - 8, h = 20 },
    trackMouseDown = true
  })

  -- 6. Separator 1: Presets section divider
  table.insert(elements, {
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0.22, alpha = 0.7 },
    frame = { x = barX, y = 130, w = barW, h = 1 }
  })

  table.insert(elements, {
    type = "text",
    text = "PRESET ITEMS (click row to select, copy button to generate)",
    textColor = { white = 0.48 },
    textSize = 9,
    textAlignment = "left",
    frame = { x = barX, y = 136, w = barW, h = 14 }
  })

  -- 7. Preset Items Rows
  local startY = 154
  for idx, it in ipairs(self.items) do
    local rowY = startY + (idx - 1) * 28
    local isActive = (idx == self.interactiveState.activeItemIndex)

    if isActive then
      table.insert(elements, {
        type = "rectangle",
        action = "strokeAndFill",
        fillColor = { red = 0.18, green = 0.22, blue = 0.30, alpha = 0.85 },
        strokeColor = { red = 0.28, green = 0.35, blue = 0.48, alpha = 0.7 },
        strokeWidth = 1,
        frame = { x = 12, y = rowY, w = W - 24, h = 26 },
        roundedRectRadii = { xRadius = 5, yRadius = 5 }
      })

      table.insert(elements, {
        type = "rectangle",
        action = "fill",
        fillColor = spec.color,
        frame = { x = 18, y = rowY + 9, w = 8, h = 8 },
        roundedRectRadii = { xRadius = 4, yRadius = 4 }
      })
    end

    -- Title
    table.insert(elements, {
      type = "text",
      text = it.title or it.id,
      textColor = isActive and { white = 1.0 } or { white = 0.85 },
      textSize = 12,
      textAlignment = "left",
      frame = { x = 32, y = rowY + 4, w = W - 105, h = 18 }
    })

    -- Quick Copy Badge (equal 4px padding on top, bottom, and right inside row container)
    local btnFill = isActive and { red = 0.28, green = 0.48, blue = 0.85, alpha = 0.95 } or { red = 0.20, green = 0.22, blue = 0.28, alpha = 0.85 }
    local btnStroke = isActive and { red = 0.42, green = 0.62, blue = 1.0, alpha = 0.85 } or { red = 0.32, green = 0.36, blue = 0.46, alpha = 0.6 }
    local btnTextCol = isActive and { white = 1.0 } or { white = 0.80 }

    table.insert(elements, {
      id = "quick_copy_" .. it.id,
      type = "rectangle",
      action = "strokeAndFill",
      fillColor = btnFill,
      strokeColor = btnStroke,
      strokeWidth = 1,
      roundedRectRadii = { xRadius = 4, yRadius = 4 },
      frame = { x = W - 62, y = rowY + 4, w = 46, h = 18 },
      trackMouseDown = true
    })

    table.insert(elements, {
      id = "quick_copy_" .. it.id,
      type = "text",
      text = "Copy",
      textColor = btnTextCol,
      textSize = 10,
      textAlignment = "center",
      frame = { x = W - 62, y = rowY + 5, w = 46, h = 16 },
      trackMouseDown = true
    })

    -- Clickable row overlay
    table.insert(elements, {
      id = "item_row_" .. idx,
      type = "rectangle",
      action = "fill",
      fillColor = { alpha = 0.001 },
      frame = { x = 12, y = rowY, w = W - 78, h = 26 },
      trackMouseDown = true
    })
  end

  -- 8. Separator 2: Utilities divider
  local sep2Y = startY + (#self.items * 28) + 2
  table.insert(elements, {
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0.22, alpha = 0.7 },
    frame = { x = barX, y = sep2Y, w = barW, h = 1 }
  })

  -- 9. Footer Menu Option: Clear Clipboard
  table.insert(elements, {
    id = "btn_clear_clipboard",
    type = "rectangle",
    action = "fill",
    fillColor = { alpha = 0.001 },
    frame = { x = 14, y = sep2Y + 6, w = W - 28, h = 22 },
    trackMouseDown = true
  })

  table.insert(elements, {
    id = "btn_clear_clipboard",
    type = "text",
    text = "🗑  Clear Clipboard Now",
    textColor = { white = 0.75 },
    textSize = 11,
    textAlignment = "left",
    frame = { x = 20, y = sep2Y + 9, w = W - 40, h = 18 },
    trackMouseDown = true
  })

  if c.replaceElements then
    c:replaceElements(elements)
  else
    while (#c > 0) do c:removeElement() end
    c:appendElements(elements)
  end
end

function obj:_handleInteractiveMouse(canvas, eventName, id, x, y)
  local W, _ = self:_getInteractiveMenuDimensions()
  local barX = 16
  local barW = W - 32

  -- 1. Preset Header Navigation
  if (id == "btn_prev" or id == "btn_next" or id == "title_cycle") and eventName == "mouseDown" then
    local count = #self.items
    if count > 0 then
      if id == "btn_prev" then
        self.interactiveState.activeItemIndex = self.interactiveState.activeItemIndex - 1
        if self.interactiveState.activeItemIndex < 1 then self.interactiveState.activeItemIndex = count end
      else
        self.interactiveState.activeItemIndex = self.interactiveState.activeItemIndex + 1
        if self.interactiveState.activeItemIndex > count then self.interactiveState.activeItemIndex = 1 end
      end
      local item = self.items[self.interactiveState.activeItemIndex]
      local spec = getItemSliderSpec(item)
      self.interactiveState.currentLength = spec.defaultVal
      self.interactiveState.hoveredSegment = nil
      local opts = self:_getInteractiveItemOpts(spec.defaultVal)
      self.interactiveState.previewPassword = self:generate(opts)
      self:_renderInteractiveMenu()
    end
    return
  end

  -- 2. Preview Box Click
  if id == "btn_preview_click" and eventName == "mouseDown" then
    local opts, _, _ = self:_getInteractiveItemOpts()
    self:copyPassword(opts)
    self:hideInteractiveMenu()
    return
  end

  -- 3. Segmented Bar Hover & Click
  if id == "slider_bar" or (id == "_canvas_" and y >= 56 and y <= 80) then
    local opts, _, spec = self:_getInteractiveItemOpts()
    local segs = math.floor((spec.max - spec.min) / spec.step) + 1
    local f = math.max(0, math.min(1, (x - barX) / barW))
    local segIdx = math.max(1, math.min(segs, math.ceil(f * segs)))
    local newVal = spec.min + (segIdx - 1) * spec.step

    if eventName == "mouseMove" or eventName == "mouseEnter" then
      if newVal ~= self.interactiveState.currentLength then
        self.interactiveState.currentLength = newVal
        self.interactiveState.hoveredSegment = segIdx
        local genOpts = self:_getInteractiveItemOpts(newVal)
        self.interactiveState.previewPassword = self:generate(genOpts)
        self:_renderInteractiveMenu()
      end
    elseif eventName == "mouseDown" then
      self.interactiveState.currentLength = newVal
      local genOpts = self:_getInteractiveItemOpts(newVal)
      self:copyPassword(genOpts)
      self:hideInteractiveMenu()
    end
    return
  end

  -- 4. Quick Copy Button on Row
  local quickCopyId = id and id:match("^quick_copy_(.*)$")
  if quickCopyId and eventName == "mouseDown" then
    self:copyPassword(quickCopyId)
    self:hideInteractiveMenu()
    return
  end

  -- 5. Preset Item Row Selection
  local rowIdx = id and tonumber(id:match("^item_row_(%d+)$"))
  if rowIdx and eventName == "mouseDown" then
    if self.items[rowIdx] then
      self.interactiveState.activeItemIndex = rowIdx
      local item = self.items[rowIdx]
      local spec = getItemSliderSpec(item)
      self.interactiveState.currentLength = spec.defaultVal
      self.interactiveState.hoveredSegment = nil
      local genOpts = self:_getInteractiveItemOpts(spec.defaultVal)
      self.interactiveState.previewPassword = self:generate(genOpts)
      self:_renderInteractiveMenu()
    end
    return
  end

  -- 6. Footer Actions
  if id == "btn_clear_clipboard" and eventName == "mouseDown" then
    if has_hs and hs.pasteboard then
      hs.pasteboard.clearContents()
      if hs.alert then hs.alert.show("Clipboard cleared") end
    end
    self:hideInteractiveMenu()
    return
  end
end

--- PasswordGenerator:showInteractiveMenu()
--- Method
--- Displays the interactive menu dropdown attached to the menubar icon with segmented length bar and preset items.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:showInteractiveMenu()
  if not has_hs or not hs.canvas then return self end

  if not self.items[self.interactiveState.activeItemIndex] then
    self.interactiveState.activeItemIndex = 1
  end
  local item = self.items[self.interactiveState.activeItemIndex] or self:getItem(self.default_item) or self.items[1]
  local spec = getItemSliderSpec(item)
  self.interactiveState.currentLength = spec.defaultVal
  self.interactiveState.hoveredSegment = nil
  local opts = self:_getInteractiveItemOpts(spec.defaultVal)
  self.interactiveState.previewPassword = self:generate(opts)

  local W, H = self:_getInteractiveMenuDimensions()
  local originX, originY

  -- Position directly underneath the menubar icon if available
  if self.menubar and self.menubar.frame then
    local mf = self.menubar:frame()
    if mf and mf.w and mf.w > 0 then
      local scr = (has_hs and hs.mouse and hs.mouse.getCurrentScreen) and hs.mouse.getCurrentScreen() or nil
      local sf = (scr and scr.fullFrame) and scr:fullFrame() or { x = 0, y = 0, w = 1920, h = 1080 }
      originX = math.min(math.max(sf.x + 10, mf.x + (mf.w / 2) - (W / 2)), sf.x + sf.w - W - 10)
      originY = mf.y + mf.h + 2
    end
  end

  if not originX then
    local mPos = (has_hs and hs.mouse and hs.mouse.getAbsolutePosition) and hs.mouse.getAbsolutePosition() or { x = 400, y = 100 }
    local scr = (has_hs and hs.mouse and hs.mouse.getCurrentScreen) and hs.mouse.getCurrentScreen() or nil
    local sf = (scr and scr.fullFrame) and scr:fullFrame() or { x = 0, y = 0, w = 1920, h = 1080 }
    originX = math.min(math.max(sf.x + 10, mPos.x - W / 2), sf.x + sf.w - W - 10)
    originY = math.min(math.max(sf.y + 30, mPos.y + 10), sf.y + sf.h - H - 10)
  end

  if not self.interactiveCanvas then
    self.interactiveCanvas = hs.canvas.new({ x = originX, y = originY, w = W, h = H })
    if hs.canvas.windowLevels and hs.canvas.windowLevels.overlay then
      self.interactiveCanvas:level(hs.canvas.windowLevels.overlay)
    end
    self.interactiveCanvas:clickActivating(false)
    self.interactiveCanvas:canvasMouseEvents(true, true, true, true)
    self.interactiveCanvas:mouseCallback(function(c, m, i, x, y)
      self:_handleInteractiveMouse(c, m, i, x, y)
    end)
  else
    self.interactiveCanvas:frame({ x = originX, y = originY, w = W, h = H })
  end

  self:_renderInteractiveMenu()
  self.interactiveCanvas:show()

  -- Outside-click listener to dismiss menu when clicking away
  if has_hs and hs.eventtap and hs.eventtap.new and hs.eventtap.event and hs.eventtap.event.types then
    if self.interactiveClickTap then self.interactiveClickTap:stop() end
    local evTypes = {}
    if hs.eventtap.event.types.leftMouseDown then table.insert(evTypes, hs.eventtap.event.types.leftMouseDown) end
    if hs.eventtap.event.types.rightMouseDown then table.insert(evTypes, hs.eventtap.event.types.rightMouseDown) end
    if #evTypes > 0 then
      self.interactiveClickTap = hs.eventtap.new(evTypes, function(event)
        if not self.interactiveCanvas then return false end
        local pos = hs.mouse.getAbsolutePosition()
        local cf = self.interactiveCanvas:frame()
        if pos.x < cf.x or pos.x > cf.x + cf.w or pos.y < cf.y or pos.y > cf.y + cf.h then
          -- If clicked inside menubar item itself, ignore outside tap (toggle handles it)
          if self.menubar and self.menubar.frame then
            local mf = self.menubar:frame()
            if mf and pos.x >= mf.x and pos.x <= mf.x + mf.w and pos.y >= mf.y and pos.y <= mf.y + mf.h then
              return false
            end
          end
          self:hideInteractiveMenu()
        end
        return false
      end)
      self.interactiveClickTap:start()
    end
  end

  -- Keyboard event listener for Escape, Return, Left, Right, Tab
  if has_hs and hs.eventtap and hs.eventtap.event and hs.eventtap.event.types and hs.eventtap.event.types.keyDown then
    if self.interactiveKeyTap then self.interactiveKeyTap:stop() end
    self.interactiveKeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
      if not self.interactiveCanvas then return false end
      local key = event:getKeyCode()
      -- 53 is Escape
      if key == 53 then
        self:hideInteractiveMenu()
        return true
      -- 36 is Return / Enter
      elseif key == 36 then
        local genOpts = self:_getInteractiveItemOpts()
        self:copyPassword(genOpts)
        self:hideInteractiveMenu()
        return true
      -- 123 is Left Arrow
      elseif key == 123 then
        local _, _, sp = self:_getInteractiveItemOpts()
        local cur = self.interactiveState.currentLength or sp.defaultVal
        if cur - sp.step >= sp.min then
          self.interactiveState.currentLength = cur - sp.step
          local genOpts = self:_getInteractiveItemOpts(self.interactiveState.currentLength)
          self.interactiveState.previewPassword = self:generate(genOpts)
          self:_renderInteractiveMenu()
        end
        return true
      -- 124 is Right Arrow
      elseif key == 124 then
        local _, _, sp = self:_getInteractiveItemOpts()
        local cur = self.interactiveState.currentLength or sp.defaultVal
        if cur + sp.step <= sp.max then
          self.interactiveState.currentLength = cur + sp.step
          local genOpts = self:_getInteractiveItemOpts(self.interactiveState.currentLength)
          self.interactiveState.previewPassword = self:generate(genOpts)
          self:_renderInteractiveMenu()
        end
        return true
      -- 48 is Tab
      elseif key == 48 then
        local count = #self.items
        if count > 0 then
          self.interactiveState.activeItemIndex = (self.interactiveState.activeItemIndex % count) + 1
          local genOpts, _, sp = self:_getInteractiveItemOpts()
          self.interactiveState.currentLength = sp.defaultVal
          self.interactiveState.previewPassword = self:generate(genOpts)
          self:_renderInteractiveMenu()
        end
        return true
      end
      return false
    end)
    self.interactiveKeyTap:start()
  end

  return self
end

--- PasswordGenerator:hideInteractiveMenu()
--- Method
--- Closes and dismisses the interactive menu dropdown.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:hideInteractiveMenu()
  if self.interactiveClickTap then
    self.interactiveClickTap:stop()
    self.interactiveClickTap = nil
  end
  if self.interactiveKeyTap then
    self.interactiveKeyTap:stop()
    self.interactiveKeyTap = nil
  end
  if self.interactiveCanvas then
    self.interactiveCanvas:hide()
    self.interactiveCanvas:delete()
    self.interactiveCanvas = nil
  end
  return self
end

--- PasswordGenerator:toggleInteractiveMenu()
--- Method
--- Toggles visibility of the interactive menu dropdown.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:toggleInteractiveMenu()
  if self.interactiveCanvas and self.interactiveCanvas._visible then
    self:hideInteractiveMenu()
  else
    self:showInteractiveMenu()
  end
  return self
end

-- Backward compatibility aliases
obj.showInteractiveHUD = obj.showInteractiveMenu
obj.hideInteractiveHUD = obj.hideInteractiveMenu

--------------------------------------------------------------------------------
-- Menubar UI
--------------------------------------------------------------------------------

obj.menubar = nil

function obj:_updateMenubar()
  if not self.menubar then return end

  if self.interactive_menu then
    -- When interactive_menu is enabled, clear native menu so clickCallback fires
    self.menubar:setMenu(nil)
    self.menubar:setClickCallback(function()
      self:toggleInteractiveMenu()
    end)
  else
    -- Fallback to standard native macOS menu
    self.menubar:setClickCallback(nil)
    local menuTable = {}

    for _, item in ipairs(self.items) do
      local itId = item.id
      local itTitle = item.title or itId
      table.insert(menuTable, {
        title = itTitle,
        fn = function(mods)
          if mods and (mods.alt or mods.cmd) then
            self:pastePassword(itId)
          else
            self:copyPassword(itId)
          end
        end
      })
    end

    if self.clipboard_clear_timeout and self.clipboard_clear_timeout > 0 then
      table.insert(menuTable, { title = "-" })
      table.insert(menuTable, {
        title = "Clear Clipboard Now",
        fn = function()
          if has_hs and hs.pasteboard then
            hs.pasteboard.clearContents()
            if hs.alert then hs.alert.show("Clipboard cleared") end
          end
        end
      })
    end

    self.menubar:setMenu(menuTable)
  end
end

--- PasswordGenerator:start()
--- Method
--- Starts the menubar display for PasswordGenerator.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:start()
  if not has_hs or not hs.menubar then return self end
  if not self.menubar then
    self.menubar = hs.menubar.new()
    if self.menubar then
      if hs.image and hs.image.imageFromName then
        local img = hs.image.imageFromName("NSLockLockedTemplate") or hs.image.imageFromName("NSSecurity")
        if img then self.menubar:setIcon(img) else self.menubar:setTitle("🔐") end
      else
        self.menubar:setTitle("🔐")
      end
    end
  end
  self:_updateMenubar()
  return self
end

--- PasswordGenerator:stop()
--- Method
--- Stops and removes the menubar item for PasswordGenerator.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PasswordGenerator object for method chaining
function obj:stop()
  if self.menubar then
    self.menubar:delete()
    self.menubar = nil
  end
  if activeClearTimer then
    activeClearTimer:stop()
    activeClearTimer = nil
  end
  self:hideInteractiveMenu()
  return self
end

-- Backward compatibility alias: showChooser opens the interactive menu
function obj:showChooser()
  return self:toggleInteractiveMenu()
end

--------------------------------------------------------------------------------
-- Hotkeys
--------------------------------------------------------------------------------

--- PasswordGenerator:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for PasswordGenerator.
---
--- Parameters:
---  * mapping - A table containing action or item IDs mapped to key details:
---    * `copy` - Generate default password and copy to clipboard
---    * `paste` - Generate default password and paste
---    * `menu` - Toggle interactive segmented-bar dropdown menu
---    * `interactive` - Toggle interactive segmented-bar dropdown menu
---    * Or any configured item ID (e.g. `diceware`, `pin`, `strong`, `passphrase`) to generate that specific item
---
--- Returns:
---  * None
function obj:bindHotkeys(mapping)
  if not has_hs or not hs.spoons or not hs.spoons.bindHotkeysToSpec then return end

  local def = {
    copy = function() self:copyPassword() end,
    paste = function() self:pastePassword() end,
    menu = function() self:toggleInteractiveMenu() end,
    interactive = function() self:toggleInteractiveMenu() end,
    choose = function() self:toggleInteractiveMenu() end
  }

  for _, item in ipairs(self.items) do
    local itId = item.id
    def[itId] = function() self:copyPassword(itId) end
  end

  hs.spoons.bindHotkeysToSpec(def, mapping)
end

return obj
