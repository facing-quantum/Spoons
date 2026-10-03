-- test_geminiusage.lua: unit tests for GeminiUsage.spoon JSON file reading (run from repo root)
package.path = "Source/GeminiUsage.spoon/?.lua;" .. package.path

local passed = 0
local failed = 0

local function assert_equal(expected, actual, msg)
  if expected == actual then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL: %s (expected: %s, got: %s)\n", msg, tostring(expected), tostring(actual)))
  end
end

local decodeCalls = 0

_G.hs = {
  json = {
    decode = function(text)
      decodeCalls = decodeCalls + 1
      return { decoded = text }
    end,
  },
}

local gemini = require("init")

local tmpPath = os.tmpname()
local function writeTmp(content)
  local f = io.open(tmpPath, "w")
  f:write(content)
  f:close()
end

-- [Test 1] Complete JSON object is decoded
print("\n[Test 1] Complete file")
writeTmp('  {"model":"gemini"}\n')
decodeCalls = 0
local parsed = gemini._readJsonFile(tmpPath)
assert_equal(1, decodeCalls, "complete object is decoded")
assert_equal('{"model":"gemini"}', parsed and parsed.decoded, "surrounding whitespace trimmed before decoding")

-- [Test 2] File caught mid-write is skipped without decoding
print("\n[Test 2] Truncated file")
writeTmp('{"cwd":"/home/user/projects","session_id":"141f1e20')
decodeCalls = 0
assert_equal(nil, gemini._readJsonFile(tmpPath), "truncated file returns nil")
assert_equal(0, decodeCalls, "truncated file never reaches hs.json.decode")

-- [Test 2b] Shorter rewrite that left the old content's tail behind (agy writes without truncating)
print("\n[Test 2b] Stale tail after the object")
writeTmp('{"model":"gemini","terminal_width":225}\n.old@example.com","terminal_width":225}\n')
decodeCalls = 0
parsed = gemini._readJsonFile(tmpPath)
assert_equal(1, decodeCalls, "first object is decoded")
assert_equal('{"model":"gemini","terminal_width":225}', parsed and parsed.decoded, "only the first line is decoded, stale tail dropped")

-- [Test 2c] Pretty-printed multi-line object is still decoded whole
print("\n[Test 2c] Multi-line object")
writeTmp('{\n  "model": "gemini"\n}\n')
decodeCalls = 0
parsed = gemini._readJsonFile(tmpPath)
assert_equal('{\n  "model": "gemini"\n}', parsed and parsed.decoded, "multi-line object decoded as a whole")

-- [Test 3] Empty file is skipped
print("\n[Test 3] Empty file")
writeTmp("")
decodeCalls = 0
assert_equal(nil, gemini._readJsonFile(tmpPath), "empty file returns nil")
assert_equal(0, decodeCalls, "empty file never reaches hs.json.decode")

-- [Test 4] Missing file
print("\n[Test 4] Missing file")
os.remove(tmpPath)
assert_equal(nil, gemini._readJsonFile(tmpPath), "missing file returns nil")

-- [Test 5] Decoder errors are contained
print("\n[Test 5] Decoder error")
writeTmp('{"bad"}')
_G.hs.json.decode = function() error("invalid JSON") end
assert_equal(nil, gemini._readJsonFile(tmpPath), "decode error returns nil")
os.remove(tmpPath)

print(string.format("\n=========================================\nTest Results: %d Passed, %d Failed\n=========================================", passed, failed))
if failed > 0 then os.exit(1) end
