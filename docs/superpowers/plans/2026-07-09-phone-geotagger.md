# Phone Geotagger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Lightroom Classic plugin that geotags selected photos from Google Timeline location history pulled off an Android phone over ADB, with a persistent accumulated history cache.

**Architecture:** Pure Lua plugin in a single `PhoneGeotagger.lrplugin` folder. Core logic (ISO-8601 time parsing, Timeline JSON parsing, history cache, track matching, timezone resolution, adb command handling) is Lightroom-independent and unit-tested with busted. A thin Lightroom layer (Info.lua, dialog, orchestrator) wires it to the catalog.

**Tech Stack:** Lua 5.1 (Lightroom's runtime), Lightroom Classic SDK, dkjson (vendored pure-Lua JSON), busted for tests, GitHub Actions CI.

**Spec:** `docs/superpowers/specs/2026-07-09-phone-geotagger-design.md`

## Global Constraints

- **Lua 5.1 compatibility everywhere** (Lightroom runs Lua 5.1): no `goto`, no `table.unpack`, no integer division operator, no `%q` reliance beyond strings.
- **Flat file layout inside `PhoneGeotagger.lrplugin/`** — Lightroom's `require` reliably resolves only the plugin root, so no subdirectories for Lua modules.
- **Core modules** (`iso8601.lua`, `timeline_parser.lua`, `history_cache.lua`, `matcher.lua`, `time_resolver.lua`, `tz_offsets.lua`, `adb_client.lua`) **must never call Lightroom's `import`** — only standard Lua. Lightroom-dependent files: `Info.lua`, `LrExec.lua`, `GeotagDialog.lua`, `GeotagMenuItem.lua`.
- License: **MIT**, copyright "2026 Shiblee Sadik". Plugin id: `com.github.mssadik.phonegeotagger`. Plugin name: **Phone Geotagger**. Menu title: `Geotag from Phone Timeline...`
- Defaults: max match gap **15 minutes**; on-phone export path **`/sdcard/Download/Timeline.json`**; adb binary **`adb`**; timezone dropdowns cover UTC−12:00 … UTC+14:00 including real :30/:45 offsets.
- Behavior rules from spec: skip photos with existing GPS unless "overwrite" checked; never write unmatched photos; all writes in one `withWriteAccessDo` block; summary reports tagged / skipped / no-match / no-EXIF-timezone counts plus first & last matched coordinates.
- Track point representation shared by all modules: `{ t = utc_seconds (number), lat = number, lon = number }`, arrays always sorted ascending by `t`.
- Run tests with `busted` from the repo root. Commit after every passing task.

---

### Task 1: Repo scaffolding, test harness, CI

**Files:**
- Create: `.gitignore`, `LICENSE`, `.busted`, `.github/workflows/test.yml`
- Create: `PhoneGeotagger.lrplugin/dkjson.lua` (vendored)
- Test: `spec/smoke_spec.lua`

**Interfaces:**
- Produces: working `busted` command; `require "dkjson"` resolvable from specs via `.busted` lpath.

- [ ] **Step 1: Install the Lua toolchain (local dev machine)**

```bash
brew install lua luarocks
luarocks install busted
busted --version
```

Expected: busted prints a version (e.g. `2.2.x`). (Homebrew Lua is 5.4; that's fine locally — CI also runs 5.1, and the Global Constraints keep code 5.1-compatible.)

- [ ] **Step 2: Create repo skeleton**

```bash
cd /Users/mssadik/projects/GeoTag
mkdir -p PhoneGeotagger.lrplugin spec/fixtures .github/workflows
```

Create `.gitignore`:

```gitignore
.DS_Store
*.tmp
luarocks/
lua_modules/
.luarocks/
```

Create `LICENSE` with the standard MIT text:

```text
MIT License

Copyright (c) 2026 Shiblee Sadik

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Create `.busted`:

```lua
return {
  _all = {
    lpath = "PhoneGeotagger.lrplugin/?.lua",
  },
  default = {
    verbose = true,
  },
}
```

- [ ] **Step 3: Vendor dkjson**

```bash
curl -fsSL -o PhoneGeotagger.lrplugin/dkjson.lua \
  https://raw.githubusercontent.com/dhkolf/dkjson/master/dkjson.lua
grep -q "David Kolf" PhoneGeotagger.lrplugin/dkjson.lua && echo OK
```

Expected: `OK`. (dkjson is MIT-licensed pure Lua — compatible with this repo's license; credit it in the README task.)

- [ ] **Step 4: Write the smoke test**

`spec/smoke_spec.lua`:

```lua
describe("test harness", function()
  it("loads the vendored dkjson from the plugin directory", function()
    local dkjson = require "dkjson"
    local doc = dkjson.decode('{"answer": 42}')
    assert.equals(42, doc.answer)
  end)
end)
```

- [ ] **Step 5: Run the smoke test**

Run: `busted spec/smoke_spec.lua`
Expected: `1 success / 0 failures`

- [ ] **Step 6: Add CI workflow**

`.github/workflows/test.yml`:

```yaml
name: tests
on: [push, pull_request]
jobs:
  busted:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        luaVersion: ["5.1", "5.4"]
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v10
        with:
          luaVersion: ${{ matrix.luaVersion }}
      - uses: leafo/gh-actions-luarocks@v4
      - run: luarocks install busted
      - run: busted
```

- [ ] **Step 7: Commit**

```bash
git add .gitignore LICENSE .busted .github PhoneGeotagger.lrplugin/dkjson.lua spec/smoke_spec.lua
git commit -m "chore: scaffold repo with busted harness, vendored dkjson, CI"
```

---

### Task 2: iso8601 module

**Files:**
- Create: `PhoneGeotagger.lrplugin/iso8601.lua`
- Test: `spec/iso8601_spec.lua`

**Interfaces:**
- Produces: `iso8601.parse(s)` → `naive_seconds, offset_seconds_or_nil` on success; `nil, error_message` on failure. `naive_seconds` is the wall-clock time counted as if it were UTC (Unix epoch seconds); `offset_seconds` is the embedded UTC offset (e.g. `-25200` for `-07:00`), or `nil` when the string carries no offset. Callers compute true UTC as `naive - offset`.

- [ ] **Step 1: Write the failing tests**

`spec/iso8601_spec.lua`:

```lua
local iso8601 = require "iso8601"

describe("iso8601.parse", function()
  it("parses the Unix epoch", function()
    local naive, offset = iso8601.parse("1970-01-01T00:00:00Z")
    assert.equals(0, naive)
    assert.equals(0, offset)
  end)

  it("parses a timestamp with a negative offset", function()
    local naive, offset = iso8601.parse("2024-05-10T14:05:00.000-07:00")
    assert.equals(1715349900, naive)   -- wall clock as-if-UTC
    assert.equals(-25200, offset)
    assert.equals(1715375100, naive - offset)  -- true UTC
  end)

  it("parses a compact offset without a colon", function()
    local naive, offset = iso8601.parse("2025-01-01T00:00:00+0630")
    assert.equals(1735689600, naive)
    assert.equals(23400, offset)
  end)

  it("returns nil offset when the string has none", function()
    local naive, offset = iso8601.parse("2016-02-29T12:00:00")
    assert.equals(1456747200, naive)   -- leap day handled
    assert.is_nil(offset)
  end)

  it("ignores fractional seconds", function()
    local naive = iso8601.parse("1970-01-01T00:00:01.999Z")
    assert.equals(1, naive)
  end)

  it("rejects garbage", function()
    local naive, err = iso8601.parse("not a date")
    assert.is_nil(naive)
    assert.is_string(err)
  end)

  it("rejects non-strings", function()
    local naive, err = iso8601.parse(nil)
    assert.is_nil(naive)
    assert.is_string(err)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/iso8601_spec.lua`
Expected: FAIL — `module 'iso8601' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/iso8601.lua`:

```lua
-- ISO 8601 timestamp parsing without os.time (which would apply the
-- computer's local timezone and corrupt the conversion).

local iso8601 = {}

-- Howard Hinnant's days-from-civil algorithm; valid across the Gregorian range.
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- Returns naive_seconds, offset_seconds|nil — or nil, error_message.
-- naive_seconds: the wall-clock time counted as if UTC (Unix epoch seconds).
-- offset_seconds: the embedded UTC offset, nil when the string has none.
function iso8601.parse(s)
  if type(s) ~= "string" then
    return nil, "timestamp is not a string"
  end
  local y, mo, d, h, mi, sec, rest =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
  if not y then
    return nil, "unrecognized timestamp: " .. s
  end
  local frac, tail = rest:match("^%.(%d+)(.*)$")
  if frac then rest = tail end
  local offset
  if rest == "Z" then
    offset = 0
  elseif rest ~= "" then
    local sign, oh, om = rest:match("^([+%-])(%d%d):?(%d%d)$")
    if not sign then
      return nil, "unrecognized timestamp: " .. s
    end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
  local naive = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  return naive, offset
end

return iso8601
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/iso8601_spec.lua`
Expected: `7 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/iso8601.lua spec/iso8601_spec.lua
git commit -m "feat: ISO 8601 parser returning naive seconds + embedded offset"
```

---

### Task 3: timeline_parser module

**Files:**
- Create: `PhoneGeotagger.lrplugin/timeline_parser.lua`
- Create: `spec/fixtures/ondevice_export.json`, `spec/fixtures/takeout_records.json`
- Test: `spec/timeline_parser_spec.lua`

**Interfaces:**
- Consumes: `iso8601.parse` (Task 2), `dkjson.decode` (Task 1).
- Produces: `timeline_parser.parse(json_text)` → sorted array of `{t, lat, lon}` on success; `nil, error_message` on invalid JSON, unrecognized format, or zero points.

- [ ] **Step 1: Create fixtures**

`spec/fixtures/ondevice_export.json` (Android on-device Timeline export shape — `semanticSegments` with `timelinePath` and `visit`, plus `rawSignals`):

```json
{
  "semanticSegments": [
    {
      "startTime": "2025-06-01T10:00:00.000+06:00",
      "endTime": "2025-06-01T10:20:00.000+06:00",
      "timelinePath": [
        { "point": "23.7805733°, 90.2792399°", "time": "2025-06-01T10:05:00.000+06:00" },
        { "point": "23.7810000°, 90.2800000°", "time": "2025-06-01T10:15:00.000+06:00" }
      ]
    },
    {
      "startTime": "2025-06-01T11:00:00.000+06:00",
      "endTime": "2025-06-01T12:00:00.000+06:00",
      "visit": {
        "topCandidate": {
          "placeLocation": { "latLng": "23.8103000°, 90.4125000°" }
        }
      }
    }
  ],
  "rawSignals": [
    {
      "position": {
        "LatLng": "23.7900000°, 90.3000000°",
        "timestamp": "2025-06-01T10:30:00.000+06:00"
      }
    }
  ]
}
```

`spec/fixtures/takeout_records.json` (legacy Google Takeout `Records.json` shape):

```json
{
  "locations": [
    {
      "latitudeE7": 237805733,
      "longitudeE7": 902792399,
      "timestamp": "2023-03-15T08:00:00.000Z"
    },
    {
      "latitudeE7": -338688200,
      "longitudeE7": 1512092550,
      "timestamp": "2023-03-16T09:30:00Z"
    }
  ]
}
```

- [ ] **Step 2: Write the failing tests**

`spec/timeline_parser_spec.lua`:

```lua
local timeline_parser = require "timeline_parser"

local function read_fixture(name)
  local f = assert(io.open("spec/fixtures/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("timeline_parser.parse", function()
  it("parses the on-device export format", function()
    local points = assert(timeline_parser.parse(read_fixture("ondevice_export.json")))
    -- 2 timelinePath + 1 rawSignal + 2 visit endpoints
    assert.equals(5, #points)
    -- sorted ascending; 10:05+06:00 == 04:05Z on 2025-06-01
    assert.equals(1748750700, points[1].t)
    assert.near(23.7805733, points[1].lat, 1e-9)
    assert.near(90.2792399, points[1].lon, 1e-9)
    -- rawSignal lands between the path points and the visit
    assert.equals(1748752200, points[3].t)
    assert.near(23.79, points[3].lat, 1e-9)
    -- visit emits identical coordinates at startTime and endTime
    assert.equals(1748754000, points[4].t)
    assert.equals(1748757600, points[5].t)
    assert.near(23.8103, points[4].lat, 1e-9)
    assert.near(90.4125, points[5].lon, 1e-9)
  end)

  it("parses the legacy Takeout Records format", function()
    local points = assert(timeline_parser.parse(read_fixture("takeout_records.json")))
    assert.equals(2, #points)
    assert.equals(1678867200, points[1].t)
    assert.near(23.7805733, points[1].lat, 1e-9)
    assert.near(90.2792399, points[1].lon, 1e-9)
    assert.equals(1678959000, points[2].t)
    assert.near(-33.86882, points[2].lat, 1e-9)
    assert.near(151.209255, points[2].lon, 1e-9)
  end)

  it("handles geo: URI points and duration-offset path entries", function()
    local json = [[{
      "semanticSegments": [
        {
          "startTime": "2025-06-01T10:00:00.000Z",
          "endTime": "2025-06-01T11:00:00.000Z",
          "timelinePath": [
            { "point": "geo:10.5,-20.25", "durationMinutesOffsetFromStartTime": "30" }
          ]
        }
      ]
    }]]
    local points = assert(timeline_parser.parse(json))
    assert.equals(1, #points)
    assert.equals(1748773800, points[1].t)  -- 10:00Z + 30 min
    assert.near(10.5, points[1].lat, 1e-9)
    assert.near(-20.25, points[1].lon, 1e-9)
  end)

  it("rejects invalid JSON with a clear error", function()
    local points, err = timeline_parser.parse("{{{nope")
    assert.is_nil(points)
    assert.matches("JSON", err)
  end)

  it("rejects unrecognized JSON shapes naming the supported formats", function()
    local points, err = timeline_parser.parse('{"something": "else"}')
    assert.is_nil(points)
    assert.matches("semanticSegments", err)
    assert.matches("Takeout", err)
  end)

  it("rejects files with zero extractable points", function()
    local points, err = timeline_parser.parse('{"semanticSegments": []}')
    assert.is_nil(points)
    assert.matches("No location points", err)
  end)
end)
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `busted spec/timeline_parser_spec.lua`
Expected: FAIL — `module 'timeline_parser' not found`

- [ ] **Step 4: Implement**

`PhoneGeotagger.lrplugin/timeline_parser.lua`:

```lua
-- Parses Google Timeline exports into sorted {t, lat, lon} track points.
-- Supported formats:
--   1. Android on-device Timeline export: { semanticSegments = {...}, rawSignals = {...} }
--   2. Legacy Google Takeout Records.json: { locations = { {latitudeE7, longitudeE7, timestamp} } }

local dkjson = require "dkjson"
local iso8601 = require "iso8601"

local timeline_parser = {}

-- Accepts "23.78°, 90.27°", "23.78, 90.27", and "geo:23.78,90.27".
local function parse_latlng(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^geo:", ""):gsub("°", "")
  local lat, lon = s:match("^%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*$")
  if not lat then return nil end
  return tonumber(lat), tonumber(lon)
end

local function utc(iso)
  local naive, offset = iso8601.parse(iso)
  if not naive then return nil end
  return naive - (offset or 0)
end

local function add(points, t, lat, lon)
  if t and lat and lon then
    points[#points + 1] = { t = t, lat = lat, lon = lon }
  end
end

local function parse_ondevice(doc, points)
  for _, seg in ipairs(doc.semanticSegments or {}) do
    local seg_start = utc(seg.startTime)
    for _, entry in ipairs(seg.timelinePath or {}) do
      local t = utc(entry.time)
      if not t and entry.durationMinutesOffsetFromStartTime and seg_start then
        local minutes = tonumber(entry.durationMinutesOffsetFromStartTime)
        if minutes then t = seg_start + minutes * 60 end
      end
      local lat, lon = parse_latlng(entry.point)
      add(points, t, lat, lon)
    end
    if seg.visit then
      local place = seg.visit.topCandidate and seg.visit.topCandidate.placeLocation
      local lat, lon = parse_latlng(place and place.latLng)
      if lat then
        -- A visit spans an interval at one place: emit both endpoints so
        -- photos taken during the visit interpolate to that place.
        add(points, seg_start, lat, lon)
        add(points, utc(seg.endTime), lat, lon)
      end
    end
  end
  for _, sig in ipairs(doc.rawSignals or {}) do
    local pos = sig.position
    if pos then
      local lat, lon = parse_latlng(pos.LatLng or pos.latLng)
      add(points, utc(pos.timestamp), lat, lon)
    end
  end
end

local function parse_takeout(doc, points)
  for _, loc in ipairs(doc.locations) do
    if loc.latitudeE7 and loc.longitudeE7 then
      local t
      if loc.timestamp then
        t = utc(loc.timestamp)
      elseif loc.timestampMs then
        local ms = tonumber(loc.timestampMs)
        if ms then t = math.floor(ms / 1000) end
      end
      add(points, t, loc.latitudeE7 / 1e7, loc.longitudeE7 / 1e7)
    end
  end
end

-- Returns a sorted array of {t, lat, lon}, or nil, error_message.
function timeline_parser.parse(json_text)
  local doc, _, jerr = dkjson.decode(json_text)
  if type(doc) ~= "table" then
    return nil, "Not valid JSON: " .. tostring(jerr)
  end
  local points = {}
  if type(doc.locations) == "table" then
    parse_takeout(doc, points)
  elseif doc.semanticSegments or doc.rawSignals then
    parse_ondevice(doc, points)
  else
    return nil, "Unrecognized file. Expected a Google Timeline on-device export "
      .. "(semanticSegments/rawSignals) or a legacy Takeout Records.json (locations)."
  end
  if #points == 0 then
    return nil, "No location points found in the file."
  end
  table.sort(points, function(a, b) return a.t < b.t end)
  return points
end

return timeline_parser
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `busted spec/timeline_parser_spec.lua`
Expected: `6 successes / 0 failures`

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/timeline_parser.lua spec/timeline_parser_spec.lua spec/fixtures
git commit -m "feat: Timeline parser for on-device and legacy Takeout formats"
```

---

### Task 4: history_cache module

**Files:**
- Create: `PhoneGeotagger.lrplugin/history_cache.lua`
- Test: `spec/history_cache_spec.lua`

**Interfaces:**
- Produces:
  - `history_cache.load(path)` → sorted points array (`{}` if file missing; malformed lines skipped).
  - `history_cache.merge(existing, incoming)` → new sorted array, deduped on integer `t` (existing wins).
  - `history_cache.save(path, points)` → `true` or `nil, error_message` (writes `path .. ".tmp"` then renames).
  - `history_cache.coverage(points)` → `nil` for empty, else `{count, first_t, last_t}`.

- [ ] **Step 1: Write the failing tests**

`spec/history_cache_spec.lua`:

```lua
local history_cache = require "history_cache"

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local path = tmpdir .. "/phone_geotagger_test_cache.csv"

describe("history_cache", function()
  before_each(function() os.remove(path) end)
  after_each(function() os.remove(path) end)

  it("loads an empty list when the file is missing", function()
    assert.same({}, history_cache.load(path))
  end)

  it("saves and reloads points, preserving order and precision", function()
    local points = {
      { t = 100, lat = 23.7805733, lon = 90.2792399 },
      { t = 200, lat = -33.86882, lon = 151.209255 },
    }
    assert.is_true(history_cache.save(path, points))
    local loaded = history_cache.load(path)
    assert.equals(2, #loaded)
    assert.equals(100, loaded[1].t)
    assert.near(23.7805733, loaded[1].lat, 1e-6)
    assert.near(151.209255, loaded[2].lon, 1e-6)
  end)

  it("skips malformed lines on load", function()
    local f = assert(io.open(path, "w"))
    f:write("100,10.5,20.5\n")
    f:write("garbage line\n")
    f:write("200,11.5,21.5\n")
    f:close()
    assert.equals(2, #history_cache.load(path))
  end)

  it("merges with existing points winning on duplicate timestamps", function()
    local existing = { { t = 100, lat = 1.0, lon = 2.0 } }
    local incoming = {
      { t = 100, lat = 9.0, lon = 9.0 },
      { t = 50, lat = 3.0, lon = 4.0 },
    }
    local merged = history_cache.merge(existing, incoming)
    assert.equals(2, #merged)
    assert.equals(50, merged[1].t)   -- sorted
    assert.equals(1.0, merged[2].lat) -- existing wins at t=100
  end)

  it("reports coverage", function()
    assert.is_nil(history_cache.coverage({}))
    local cov = history_cache.coverage({
      { t = 100, lat = 1, lon = 2 },
      { t = 900, lat = 3, lon = 4 },
    })
    assert.same({ count = 2, first_t = 100, last_t = 900 }, cov)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/history_cache_spec.lua`
Expected: FAIL — `module 'history_cache' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/history_cache.lua`:

```lua
-- Persistent accumulated location history: one CSV line per point,
-- "utc_seconds,lat,lon". Every Timeline export the user imports is merged
-- in, so old photos can be geotagged without the phone connected.

local history_cache = {}

-- Returns a sorted points array; {} when the file doesn't exist.
function history_cache.load(path)
  local points = {}
  local f = io.open(path, "r")
  if not f then return points end
  for line in f:lines() do
    local t, lat, lon = line:match("^(%-?%d+),(%-?[%d%.]+),(%-?[%d%.]+)%s*$")
    if t then
      points[#points + 1] = { t = tonumber(t), lat = tonumber(lat), lon = tonumber(lon) }
    end
  end
  f:close()
  table.sort(points, function(a, b) return a.t < b.t end)
  return points
end

-- Returns a new sorted array; on duplicate integer timestamps the existing
-- point wins (re-importing an export must not churn the cache).
function history_cache.merge(existing, incoming)
  local seen, out = {}, {}
  local function absorb(list)
    for _, p in ipairs(list) do
      local k = math.floor(p.t)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = { t = k, lat = p.lat, lon = p.lon }
      end
    end
  end
  absorb(existing)
  absorb(incoming)
  table.sort(out, function(a, b) return a.t < b.t end)
  return out
end

-- Writes to path..".tmp" then renames, so a crash can't truncate the cache.
function history_cache.save(path, points)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  for _, p in ipairs(points) do
    f:write(string.format("%d,%.7f,%.7f\n", p.t, p.lat, p.lon))
  end
  f:close()
  os.remove(path) -- Windows os.rename refuses to overwrite
  local ok, rerr = os.rename(tmp, path)
  if not ok then return nil, rerr end
  return true
end

-- nil for empty, else { count, first_t, last_t }.
function history_cache.coverage(points)
  if #points == 0 then return nil end
  return { count = #points, first_t = points[1].t, last_t = points[#points].t }
end

return history_cache
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/history_cache_spec.lua`
Expected: `5 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/history_cache.lua spec/history_cache_spec.lua
git commit -m "feat: persistent accumulated history cache with dedup merge"
```

---

### Task 5: matcher module

**Files:**
- Create: `PhoneGeotagger.lrplugin/matcher.lua`
- Test: `spec/matcher_spec.lua`

**Interfaces:**
- Consumes: sorted points arrays (shape from Global Constraints).
- Produces: `matcher.match(points, t, max_gap_seconds)` → `lat, lon` on success; `nil, "empty"` for an empty track; `nil, "no_match"` when nothing is within tolerance. Interpolates linearly when the bracketing points are ≤ `max_gap_seconds` apart; otherwise falls back to the nearest single point within `max_gap_seconds`.

- [ ] **Step 1: Write the failing tests**

`spec/matcher_spec.lua`:

```lua
local matcher = require "matcher"

local track = {
  { t = 1000, lat = 10.0, lon = 20.0 },
  { t = 2000, lat = 12.0, lon = 22.0 },
  { t = 10000, lat = 50.0, lon = 60.0 },
}

describe("matcher.match", function()
  it("interpolates between bracketing points within the gap", function()
    local lat, lon = matcher.match(track, 1500, 3600)
    assert.near(11.0, lat, 1e-9)
    assert.near(21.0, lon, 1e-9)
  end)

  it("returns an exact point on a direct hit", function()
    local lat, lon = matcher.match(track, 2000, 60)
    assert.equals(12.0, lat)
    assert.equals(22.0, lon)
  end)

  it("falls back to the nearest point when the bracket gap is too wide", function()
    -- bracket 2000..10000 is 8000s wide; gap limit 600s; photo at 2300 is
    -- 300s from the point at 2000
    local lat, lon = matcher.match(track, 2300, 600)
    assert.equals(12.0, lat)
    assert.equals(22.0, lon)
  end)

  it("rejects when the nearest point exceeds the gap", function()
    local lat, reason = matcher.match(track, 5000, 600)
    assert.is_nil(lat)
    assert.equals("no_match", reason)
  end)

  it("matches before the first point within the gap", function()
    local lat = matcher.match(track, 900, 600)
    assert.equals(10.0, lat)
  end)

  it("rejects before the first point beyond the gap", function()
    local lat, reason = matcher.match(track, 100, 600)
    assert.is_nil(lat)
    assert.equals("no_match", reason)
  end)

  it("matches after the last point within the gap", function()
    local lat = matcher.match(track, 10300, 600)
    assert.equals(50.0, lat)
  end)

  it("rejects an empty track", function()
    local lat, reason = matcher.match({}, 1000, 600)
    assert.is_nil(lat)
    assert.equals("empty", reason)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/matcher_spec.lua`
Expected: FAIL — `module 'matcher' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/matcher.lua`:

```lua
-- Matches a UTC timestamp against a sorted track of {t, lat, lon} points.

local matcher = {}

-- Returns lat, lon — or nil, "empty" | "no_match".
function matcher.match(points, t, max_gap)
  local n = #points
  if n == 0 then return nil, "empty" end

  -- lo = first index with points[lo].t >= t (binary search)
  local lo, hi = 1, n + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if points[mid].t < t then lo = mid + 1 else hi = mid end
  end
  local after = points[lo]
  local before = points[lo - 1]

  if after and after.t == t then
    return after.lat, after.lon
  end
  if before and after and (after.t - before.t) <= max_gap then
    local f = (t - before.t) / (after.t - before.t)
    return before.lat + (after.lat - before.lat) * f,
           before.lon + (after.lon - before.lon) * f
  end
  local nearest
  if before and after then
    nearest = (t - before.t) <= (after.t - t) and before or after
  else
    nearest = before or after
  end
  if math.abs(nearest.t - t) <= max_gap then
    return nearest.lat, nearest.lon
  end
  return nil, "no_match"
end

return matcher
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/matcher_spec.lua`
Expected: `8 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/matcher.lua spec/matcher_spec.lua
git commit -m "feat: track matcher with interpolation and gap tolerance"
```

---

### Task 6: time_resolver + tz_offsets modules

**Files:**
- Create: `PhoneGeotagger.lrplugin/time_resolver.lua`, `PhoneGeotagger.lrplugin/tz_offsets.lua`
- Test: `spec/time_resolver_spec.lua`, `spec/tz_offsets_spec.lua`

**Interfaces:**
- Consumes: `iso8601.parse` (Task 2).
- Produces:
  - `time_resolver.resolve(capture_time_iso, opts)` → `utc_seconds, used_home_fallback` or `nil, error_message`. `opts = { override_offset = seconds|nil, home_offset = seconds, drift = seconds_camera_runs_fast|nil }`. Priority: `override_offset` (home/destination radio) > embedded EXIF offset > `home_offset` fallback (sets `used_home_fallback = true`). `drift` is subtracted last.
  - `tz_offsets.items()` → ascending array of `{ title = "UTC+06:00", value = 21600 }` covering UTC−12:00…UTC+14:00 including real :30/:45 offsets — the exact shape Lightroom `popup_menu` wants.
  - `tz_offsets.format(seconds)` → `"UTC+06:00"` style string.

- [ ] **Step 1: Write the failing tests**

`spec/time_resolver_spec.lua`:

```lua
local time_resolver = require "time_resolver"

describe("time_resolver.resolve", function()
  it("uses the embedded EXIF offset by default", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00", { home_offset = 21600 })
    assert.equals(1715375100, utc)
    assert.is_false(fallback)
  end)

  it("falls back to the home offset when EXIF has none", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00", { home_offset = 21600 })
    assert.equals(1715328300, utc) -- naive 1715349900 - 21600
    assert.is_true(fallback)
  end)

  it("lets an explicit override beat the EXIF offset", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00",
      { override_offset = -28800, home_offset = 21600 })
    assert.equals(1715378700, utc) -- naive 1715349900 + 28800
    assert.is_false(fallback)
  end)

  it("subtracts clock drift (camera running fast)", function()
    local utc = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00", { home_offset = 0, drift = 60 })
    assert.equals(1715375040, utc)
  end)

  it("propagates parse errors", function()
    local utc, err = time_resolver.resolve("garbage", { home_offset = 0 })
    assert.is_nil(utc)
    assert.is_string(err)
  end)
end)
```

`spec/tz_offsets_spec.lua`:

```lua
local tz_offsets = require "tz_offsets"

describe("tz_offsets", function()
  it("formats offsets", function()
    assert.equals("UTC+06:00", tz_offsets.format(21600))
    assert.equals("UTC-09:30", tz_offsets.format(-34200))
    assert.equals("UTC+00:00", tz_offsets.format(0))
  end)

  it("spans UTC-12:00 to UTC+14:00 ascending", function()
    local items = tz_offsets.items()
    assert.equals(-43200, items[1].value)
    assert.equals(50400, items[#items].value)
    for i = 2, #items do
      assert.is_true(items[i].value > items[i - 1].value)
    end
  end)

  it("includes the odd real-world offsets", function()
    local values = {}
    for _, item in ipairs(tz_offsets.items()) do values[item.value] = item.title end
    assert.equals("UTC+05:45", values[20700])  -- Nepal
    assert.equals("UTC+05:30", values[19800])  -- India
    assert.equals("UTC-03:30", values[-12600]) -- Newfoundland
    assert.equals("UTC+12:45", values[45900])  -- Chatham
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/time_resolver_spec.lua spec/tz_offsets_spec.lua`
Expected: FAIL — modules not found

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/time_resolver.lua`:

```lua
-- Converts a photo capture time (ISO 8601 string from Lightroom) to UTC.

local iso8601 = require "iso8601"

local time_resolver = {}

-- opts:
--   override_offset  seconds; when set, ignores any EXIF offset
--                    (the home/destination radio choices in the dialog)
--   home_offset      seconds; fallback when the photo has no EXIF offset
--   drift            seconds the camera clock runs fast; subtracted (default 0)
-- Returns utc_seconds, used_home_fallback — or nil, error_message.
function time_resolver.resolve(capture_time, opts)
  local naive, embedded = iso8601.parse(capture_time)
  if not naive then return nil, embedded end
  local offset, used_fallback
  if opts.override_offset then
    offset, used_fallback = opts.override_offset, false
  elseif embedded then
    offset, used_fallback = embedded, false
  else
    offset, used_fallback = opts.home_offset, true
  end
  return naive - offset - (opts.drift or 0), used_fallback
end

return time_resolver
```

`PhoneGeotagger.lrplugin/tz_offsets.lua`:

```lua
-- UTC offset choices for the home/destination dropdowns.

local tz_offsets = {}

-- All whole-hour offsets plus the real-world :30/:45 zones.
local OFFSET_MINUTES = {
  -720, -660, -600, -570, -540, -480, -420, -360, -300, -240, -210, -180,
  -120, -60, 0, 60, 120, 180, 210, 240, 270, 300, 330, 345, 360, 390, 420,
  480, 525, 540, 570, 600, 630, 660, 720, 765, 780, 840,
}

function tz_offsets.format(seconds)
  local sign = seconds < 0 and "-" or "+"
  local abs = math.abs(seconds)
  return string.format("UTC%s%02d:%02d",
    sign, math.floor(abs / 3600), math.floor((abs % 3600) / 60))
end

-- Shape consumed directly by Lightroom's popup_menu `items`.
function tz_offsets.items()
  local items = {}
  for i, minutes in ipairs(OFFSET_MINUTES) do
    items[i] = { title = tz_offsets.format(minutes * 60), value = minutes * 60 }
  end
  return items
end

return tz_offsets
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/time_resolver_spec.lua spec/tz_offsets_spec.lua`
Expected: `8 successes / 0 failures`

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: all specs pass, `0 failures`

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/time_resolver.lua PhoneGeotagger.lrplugin/tz_offsets.lua spec/time_resolver_spec.lua spec/tz_offsets_spec.lua
git commit -m "feat: capture-time UTC resolver and timezone offset choices"
```

---

### Task 7: adb_client module

**Files:**
- Create: `PhoneGeotagger.lrplugin/adb_client.lua`
- Test: `spec/adb_client_spec.lua`

**Interfaces:**
- Consumes: an injected `exec(command) → exit_status, output_text` function (real implementation arrives in Task 8 as `LrExec.execute`; tests use fakes).
- Produces:
  - `adb_client.pull_command(adb_path, remote_path, local_path)` → quoted command string.
  - `adb_client.pull(exec, adb_path, remote_path, local_path)` → `true` on success, else `nil, code, message` with `code` ∈ `"adb_not_found" | "no_device" | "remote_missing" | "adb_error"` and `message` human-readable and actionable.

- [ ] **Step 1: Write the failing tests**

`spec/adb_client_spec.lua`:

```lua
local adb_client = require "adb_client"

local function fake_exec(status, output)
  local calls = {}
  return function(cmd)
    calls[#calls + 1] = cmd
    return status, output
  end, calls
end

describe("adb_client", function()
  it("builds a fully quoted pull command", function()
    local cmd = adb_client.pull_command(
      "/opt/platform-tools/adb", "/sdcard/Download/Timeline.json", "/tmp/t.json")
    assert.equals(
      '"/opt/platform-tools/adb" pull "/sdcard/Download/Timeline.json" "/tmp/t.json"',
      cmd)
  end)

  it("returns true on success", function()
    local exec, calls = fake_exec(0, "1 file pulled, 0 skipped.")
    assert.is_true(adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json"))
    assert.equals(1, #calls)
  end)

  it("classifies a missing adb binary", function()
    local exec = fake_exec(127, "sh: adb: command not found")
    local ok, code, msg = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("adb_not_found", code)
    assert.matches("adb", msg)
  end)

  it("classifies the Windows missing-binary message", function()
    local exec = fake_exec(1,
      "'adb' is not recognized as an internal or external command")
    local ok, code = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("adb_not_found", code)
  end)

  it("classifies no connected device", function()
    local exec = fake_exec(1, "adb: no devices/emulators found")
    local ok, code, msg = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("no_device", code)
    assert.matches("USB debugging", msg)
  end)

  it("classifies an unauthorized device as no_device", function()
    local exec = fake_exec(1, "adb: device unauthorized.\nThis adb server's...")
    local ok, code = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("no_device", code)
  end)

  it("classifies a missing remote file", function()
    local exec = fake_exec(1,
      "adb: error: remote object '/sdcard/Download/Timeline.json' does not exist")
    local ok, code, msg = adb_client.pull(
      exec, "adb", "/sdcard/Download/Timeline.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("remote_missing", code)
    assert.matches("Timeline", msg)
  end)

  it("falls back to a generic error with the raw output", function()
    local exec = fake_exec(1, "something exploded")
    local ok, code, msg = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("adb_error", code)
    assert.matches("something exploded", msg)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/adb_client_spec.lua`
Expected: FAIL — `module 'adb_client' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/adb_client.lua`:

```lua
-- Builds and interprets adb commands. Execution is injected (exec function)
-- so this module stays Lightroom-free and unit-testable.

local adb_client = {}

local function q(s) return '"' .. s .. '"' end

function adb_client.pull_command(adb_path, remote_path, local_path)
  return q(adb_path) .. " pull " .. q(remote_path) .. " " .. q(local_path)
end

-- exec: function(command) -> exit_status, output_text
-- Returns true — or nil, code, message where code is one of
-- "adb_not_found" | "no_device" | "remote_missing" | "adb_error".
function adb_client.pull(exec, adb_path, remote_path, local_path)
  local status, output = exec(adb_client.pull_command(adb_path, remote_path, local_path))
  if status == 0 then return true end
  local low = (output or ""):lower()
  if status == 127
      or low:find("command not found", 1, true)
      or low:find("not recognized", 1, true) then
    return nil, "adb_not_found",
      "Could not run adb ('" .. adb_path .. "'). Install Android platform-tools "
      .. "or set the full adb path in the dialog."
  end
  if low:find("no devices", 1, true)
      or low:find("device offline", 1, true)
      or low:find("unauthorized", 1, true) then
    return nil, "no_device",
      "No Android device reachable over ADB. Connect the phone, enable "
      .. "USB debugging, and accept the authorization prompt on the phone."
  end
  if low:find("does not exist", 1, true) or low:find("no such file", 1, true) then
    return nil, "remote_missing",
      "No export found at '" .. remote_path .. "' on the phone. Export your "
      .. "Timeline data (Settings > Location > Timeline > Export) to that "
      .. "path, or correct the on-phone path in the dialog."
  end
  return nil, "adb_error",
    "adb failed (exit " .. tostring(status) .. "): " .. (output or "")
end

return adb_client
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/adb_client_spec.lua`
Expected: `8 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/adb_client.lua spec/adb_client_spec.lua
git commit -m "feat: adb pull command builder with error classification"
```

---

### Task 8: Plugin shell — Info.lua, LrExec, dialog

**Files:**
- Create: `PhoneGeotagger.lrplugin/Info.lua`, `PhoneGeotagger.lrplugin/LrExec.lua`, `PhoneGeotagger.lrplugin/GeotagDialog.lua`, `PhoneGeotagger.lrplugin/GeotagMenuItem.lua` (temporary body, replaced in Task 9)

**Interfaces:**
- Consumes: `tz_offsets.items()/format()`, `history_cache.load/merge/save/coverage`, `timeline_parser.parse`, `adb_client.pull` from earlier tasks.
- Produces:
  - `LrExec.execute(command)` → `exit_status, combined_output_text` (the real `exec` injected into `adb_client.pull`). Must be called from an async task.
  - `GeotagDialog.run(args)` with `args = { photo_count, points, cache_path, prefs }` → settings table `{ points, override_offset (seconds|nil), home_offset, drift, max_gap_sec, overwrite }` or `nil` on cancel. Task 9's orchestrator consumes exactly this shape.

These files run only inside Lightroom — no busted specs; verification is a manual smoke test in Lightroom Classic.

- [ ] **Step 1: Write Info.lua**

`PhoneGeotagger.lrplugin/Info.lua`:

```lua
return {
  LrSdkVersion = 6.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = "com.github.mssadik.phonegeotagger",
  LrPluginName = "Phone Geotagger",
  LrPluginInfoUrl = "https://github.com/mssadik/phone-geotagger",
  LrLibraryMenuItems = {
    {
      title = "Geotag from Phone Timeline...",
      file = "GeotagMenuItem.lua",
    },
  },
  VERSION = { major = 0, minor = 1, revision = 0 },
}
```

- [ ] **Step 2: Write LrExec.lua**

`PhoneGeotagger.lrplugin/LrExec.lua`:

```lua
-- Runs a shell command and captures combined stdout/stderr, which
-- LrTasks.execute alone cannot do. Must be called from an async task.

local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local LrExec = {}

function LrExec.execute(cmd)
  local out = LrPathUtils.child(
    LrPathUtils.getStandardFilePath("temp"),
    string.format("phone_geotagger_out_%d.txt", math.random(1e9)))
  local full = cmd .. ' > "' .. out .. '" 2>&1'
  if WIN_ENV then
    full = '"' .. full .. '"' -- cmd.exe strips the outer quotes
  end
  local status = LrTasks.execute(full)
  local text = ""
  if LrFileUtils.exists(out) then
    text = LrFileUtils.readFile(out) or ""
    LrFileUtils.delete(out)
  end
  return status, text
end

return LrExec
```

- [ ] **Step 3: Write GeotagDialog.lua**

`PhoneGeotagger.lrplugin/GeotagDialog.lua`:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"

local tz_offsets = require "tz_offsets"
local history_cache = require "history_cache"
local timeline_parser = require "timeline_parser"
local adb_client = require "adb_client"
local LrExec = require "LrExec"

local GeotagDialog = {}

local function coverage_text(points)
  local cov = history_cache.coverage(points)
  if not cov then
    return "Cache: empty — pull from phone or import a file"
  end
  return string.format("Cache: %d points, %s → %s", cov.count,
    os.date("!%Y-%m-%d", cov.first_t), os.date("!%Y-%m-%d", cov.last_t))
end

-- args: { photo_count, points, cache_path, prefs }
-- Returns { points, override_offset, home_offset, drift, max_gap_sec,
-- overwrite } or nil on cancel.
function GeotagDialog.run(args)
  local prefs = args.prefs
  local points = args.points
  local result

  LrFunctionContext.callWithContext("GeotagDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.mode = prefs.mode or "exif"
    props.home_offset = prefs.home_offset or 0
    props.dest_offset = prefs.dest_offset or 0
    props.drift = prefs.drift or 0
    props.max_gap_min = prefs.max_gap_min or 15
    props.overwrite = prefs.overwrite or false
    props.adb_path = prefs.adb_path or "adb"
    props.phone_path = prefs.phone_path or "/sdcard/Download/Timeline.json"
    props.coverage = coverage_text(points)

    local function absorb_file(file_path)
      local fh = io.open(file_path, "rb")
      if not fh then
        LrDialogs.message("Import failed", "Could not read " .. file_path, "warning")
        return
      end
      local text = fh:read("*a")
      fh:close()
      local new_points, err = timeline_parser.parse(text)
      if not new_points then
        LrDialogs.message("Import failed", err, "warning")
        return
      end
      points = history_cache.merge(points, new_points)
      local ok, serr = history_cache.save(args.cache_path, points)
      if not ok then
        LrDialogs.message("Cache write failed", tostring(serr), "warning")
      end
      props.coverage = coverage_text(points)
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),

      f:group_box {
        title = "Location history",
        fill_horizontal = 1,
        f:static_text { title = bind "coverage", fill_horizontal = 1 },
        f:row {
          f:push_button {
            title = "Pull latest from phone (ADB)",
            action = function()
              LrTasks.startAsyncTask(function()
                local tmp = LrPathUtils.child(
                  LrPathUtils.getStandardFilePath("temp"),
                  "phone_geotagger_pull.json")
                local ok, _, msg = adb_client.pull(
                  LrExec.execute, props.adb_path, props.phone_path, tmp)
                if not ok then
                  LrDialogs.message("ADB pull failed", msg, "warning")
                  return
                end
                absorb_file(tmp)
              end)
            end,
          },
          f:push_button {
            title = "Import file…",
            action = function()
              local files = LrDialogs.runOpenPanel {
                title = "Choose Timeline export",
                allowsMultipleSelection = false,
                canChooseDirectories = false,
              }
              if files and files[1] then absorb_file(files[1]) end
            end,
          },
        },
        f:row {
          f:static_text { title = "adb path:" },
          f:edit_field { value = bind "adb_path", fill_horizontal = 1 },
        },
        f:row {
          f:static_text { title = "On-phone export path:" },
          f:edit_field { value = bind "phone_path", fill_horizontal = 1 },
        },
      },

      f:group_box {
        title = "Camera time",
        fill_horizontal = 1,
        f:radio_button {
          title = "Camera's timezone setting is correct (use EXIF offset)",
          value = bind "mode", checked_value = "exif",
        },
        f:row {
          f:radio_button {
            title = "Clock was on home time",
            value = bind "mode", checked_value = "home",
          },
          f:popup_menu { items = tz_offsets.items(), value = bind "home_offset" },
        },
        f:row {
          f:radio_button {
            title = "Clock was on destination time",
            value = bind "mode", checked_value = "dest",
          },
          f:popup_menu { items = tz_offsets.items(), value = bind "dest_offset" },
        },
        f:row {
          f:static_text { title = "Clock drift (seconds fast):" },
          f:edit_field {
            value = bind "drift", width_in_chars = 6,
            validate = function(_, v)
              local n = tonumber(v)
              if n then return true, n end
              return false, 0, "Enter a number of seconds"
            end,
          },
        },
      },

      f:group_box {
        title = "Matching",
        fill_horizontal = 1,
        f:row {
          f:static_text { title = "Maximum time gap (minutes):" },
          f:edit_field {
            value = bind "max_gap_min", width_in_chars = 6,
            validate = function(_, v)
              local n = tonumber(v)
              if n and n > 0 then return true, n end
              return false, 15, "Enter minutes greater than zero"
            end,
          },
        },
        f:checkbox {
          title = "Overwrite existing GPS coordinates",
          value = bind "overwrite",
        },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Geotag from Phone Timeline",
      contents = contents,
      actionVerb = string.format("Geotag %d photos", args.photo_count),
    }
    if action ~= "ok" then return end

    prefs.mode = props.mode
    prefs.home_offset = props.home_offset
    prefs.dest_offset = props.dest_offset
    prefs.drift = props.drift
    prefs.max_gap_min = props.max_gap_min
    prefs.overwrite = props.overwrite and true or false
    prefs.adb_path = props.adb_path
    prefs.phone_path = props.phone_path

    local override
    if props.mode == "home" then
      override = props.home_offset
    elseif props.mode == "dest" then
      override = props.dest_offset
    end

    result = {
      points = points,
      override_offset = override,
      home_offset = props.home_offset,
      drift = tonumber(props.drift) or 0,
      max_gap_sec = (tonumber(props.max_gap_min) or 15) * 60,
      overwrite = props.overwrite and true or false,
    }
  end)

  return result
end

return GeotagDialog
```

- [ ] **Step 4: Write the temporary GeotagMenuItem.lua smoke-test body**

`PhoneGeotagger.lrplugin/GeotagMenuItem.lua` (replaced in Task 9):

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local LrPrefs = import "LrPrefs"

local history_cache = require "history_cache"
local tz_offsets = require "tz_offsets"
local GeotagDialog = require "GeotagDialog"

local function cache_path()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return LrPathUtils.child(dir, "history.csv")
end

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local photos = catalog:getTargetPhotos()
  if not photos or #photos == 0 then
    LrDialogs.message("Phone Geotagger",
      "Select photos in the Library grid first.", "info")
    return
  end

  local prefs = LrPrefs.prefsForPlugin()
  local cpath = cache_path()
  local points = history_cache.load(cpath)

  local settings = GeotagDialog.run {
    photo_count = #photos, points = points, cache_path = cpath, prefs = prefs,
  }
  if not settings then return end

  -- Temporary: echo the chosen settings instead of geotagging (Task 9
  -- replaces this with the real pipeline).
  LrDialogs.message("Phone Geotagger (smoke test)", string.format(
    "points=%d override=%s home=%s drift=%d gap=%ds overwrite=%s",
    #settings.points,
    settings.override_offset and tz_offsets.format(settings.override_offset) or "EXIF",
    tz_offsets.format(settings.home_offset),
    settings.drift, settings.max_gap_sec, tostring(settings.overwrite)), "info")
end)
```

- [ ] **Step 5: Manual smoke test in Lightroom Classic**

1. Lightroom Classic → File → Plug-in Manager → Add → select `PhoneGeotagger.lrplugin` → plugin loads with no error, shows "Phone Geotagger".
2. With no photos selected: Library → Plug-in Extras → Geotag from Phone Timeline... → message says to select photos.
3. Select a few photos → run again → dialog appears matching the spec mockup: coverage line ("Cache: empty…"), Pull/Import buttons, adb/phone path fields, three camera-time radios with two timezone popups, drift field, gap field, overwrite checkbox, action button reads "Geotag N photos".
4. Click "Import file…" → choose `spec/fixtures/ondevice_export.json` → coverage line updates to "Cache: 5 points, 2025-06-01 → 2025-06-01".
5. Cancel and reopen → coverage persists (cache file was written).
6. With the phone connected (USB debugging on) and an export at `/sdcard/Download/Timeline.json`: "Pull latest from phone (ADB)" merges points and updates coverage. Without a phone: a clear "No Android device reachable" warning appears.
7. Click the action button → smoke-test summary shows the settings values; reopen and confirm radio/popup/gap selections persisted.

Fix anything that fails before committing. (Common trap: if `require` fails inside Lightroom, check the file is flat in the plugin root — see Global Constraints.)

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/Info.lua PhoneGeotagger.lrplugin/LrExec.lua PhoneGeotagger.lrplugin/GeotagDialog.lua PhoneGeotagger.lrplugin/GeotagMenuItem.lua
git commit -m "feat: Lightroom plugin shell — manifest, exec helper, run dialog"
```

---

### Task 9: Geotagging pipeline (orchestrator)

**Files:**
- Modify: `PhoneGeotagger.lrplugin/GeotagMenuItem.lua` (replace the smoke-test body after the dialog call)

**Interfaces:**
- Consumes: `GeotagDialog.run` settings table (Task 8), `time_resolver.resolve` (Task 6), `matcher.match` (Task 5), `tz_offsets.format` (Task 6), Lightroom SDK (`getRawMetadata("gps")`, `getRawMetadata("dateTimeOriginalISO8601")`, `setRawMetadata("gps", {latitude, longitude})`, `LrProgressScope`).
- Produces: the complete user-facing feature.

- [ ] **Step 1: Replace GeotagMenuItem.lua with the full pipeline**

`PhoneGeotagger.lrplugin/GeotagMenuItem.lua` (entire file):

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"

local history_cache = require "history_cache"
local matcher = require "matcher"
local time_resolver = require "time_resolver"
local tz_offsets = require "tz_offsets"
local GeotagDialog = require "GeotagDialog"

local function cache_path()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return LrPathUtils.child(dir, "history.csv")
end

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local photos = catalog:getTargetPhotos()
  if not photos or #photos == 0 then
    LrDialogs.message("Phone Geotagger",
      "Select photos in the Library grid first.", "info")
    return
  end

  local prefs = LrPrefs.prefsForPlugin()
  local cpath = cache_path()
  local points = history_cache.load(cpath)

  local settings = GeotagDialog.run {
    photo_count = #photos, points = points, cache_path = cpath, prefs = prefs,
  }
  if not settings then return end
  if #settings.points == 0 then
    LrDialogs.message("Phone Geotagger",
      "No location history available. Pull from the phone or import an "
      .. "export file first.", "warning")
    return
  end

  local stats = { skipped = 0, unmatched = 0, no_time = 0, no_tz = 0 }
  local writes = {}
  local progress = LrProgressScope { title = "Geotagging from phone Timeline" }
  progress:setCancelable(true)

  for i, photo in ipairs(photos) do
    if progress:isCanceled() then break end
    progress:setPortionComplete(i - 1, #photos)

    local gps = photo:getRawMetadata("gps")
    if gps and gps.latitude and not settings.overwrite then
      stats.skipped = stats.skipped + 1
    else
      local iso = photo:getRawMetadata("dateTimeOriginalISO8601")
      if not iso or iso == "" then
        stats.no_time = stats.no_time + 1
      else
        local utc, extra = time_resolver.resolve(iso, {
          override_offset = settings.override_offset,
          home_offset = settings.home_offset,
          drift = settings.drift,
        })
        if not utc then
          stats.no_time = stats.no_time + 1
        else
          if extra == true then stats.no_tz = stats.no_tz + 1 end
          local lat, lon = matcher.match(settings.points, utc, settings.max_gap_sec)
          if lat then
            writes[#writes + 1] = { photo = photo, lat = lat, lon = lon }
          else
            stats.unmatched = stats.unmatched + 1
          end
        end
      end
    end
  end

  if #writes > 0 then
    catalog:withWriteAccessDo("Geotag from Phone Timeline", function()
      for _, w in ipairs(writes) do
        w.photo:setRawMetadata("gps", { latitude = w.lat, longitude = w.lon })
      end
    end)
  end
  progress:done()

  local lines = {
    string.format("Tagged: %d", #writes),
    string.format("Skipped (already had GPS): %d", stats.skipped),
    string.format("No match in history: %d", stats.unmatched),
  }
  if stats.no_time > 0 then
    lines[#lines + 1] = string.format("No usable capture time: %d", stats.no_time)
  end
  if stats.no_tz > 0 and not settings.override_offset then
    lines[#lines + 1] = string.format(
      "No EXIF timezone (assumed home %s): %d",
      tz_offsets.format(settings.home_offset), stats.no_tz)
  end
  if #writes > 0 then
    local first, last = writes[1], writes[#writes]
    lines[#lines + 1] = string.format("First match: %.5f, %.5f (%s)",
      first.lat, first.lon, first.photo:getFormattedMetadata("fileName"))
    lines[#lines + 1] = string.format("Last match: %.5f, %.5f (%s)",
      last.lat, last.lon, last.photo:getFormattedMetadata("fileName"))
  end
  LrDialogs.message("Phone Geotagger — done", table.concat(lines, "\n"), "info")
end)
```

- [ ] **Step 2: Run the full unit suite (guard against regressions)**

Run: `busted`
Expected: all specs pass, `0 failures`

- [ ] **Step 3: Manual end-to-end test in Lightroom Classic**

Setup: reload the plugin (Plug-in Manager → select Phone Geotagger → Reload Plug-in). Use test photos whose capture times fall inside the fixture's range (2025-06-01 04:05–06:00 UTC), or import a real Timeline export covering real photos.

1. Select photos → run → import/pull history → set camera-time mode → Geotag.
2. Summary reports plausible counts and first/last coordinates.
3. Open the Map module → tagged photos appear at the expected locations.
4. Re-run on the same photos without "overwrite" → all counted as "Skipped (already had GPS)".
5. Re-run with "overwrite" checked → photos re-tagged.
6. Select a photo far outside history coverage → counted under "No match in history", GPS untouched.
7. Metadata panel: GPS field is populated; Metadata → Save Metadata to File writes it to XMP/file as normal Lightroom behavior.

- [ ] **Step 4: Commit**

```bash
git add PhoneGeotagger.lrplugin/GeotagMenuItem.lua
git commit -m "feat: full geotagging pipeline with progress and summary"
```

---

### Task 10: README and packaging polish

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything — this documents the finished plugin for GitHub users.

- [ ] **Step 1: Write README.md**

```markdown
# Phone Geotagger for Lightroom Classic

Geotag your camera photos using the location history already on your Android
phone. No subscription services, no uploading your photos anywhere — your
phone's Google Timeline is the GPS track logger you've been carrying all
along.

## How it works

1. On your phone, export your Timeline data
   (**Settings → Location → Timeline → Export Timeline data**) and save the
   JSON to `Download/Timeline.json`.
2. In Lightroom Classic, select photos and run
   **Library → Plug-in Extras → Geotag from Phone Timeline...**
3. Click **Pull latest from phone (ADB)** (or **Import file…** to browse to a
   copy of the export).
4. Click **Geotag**. Each photo's capture time is converted to UTC and matched
   against your location track; matched photos get GPS coordinates written to
   the catalog.

Every export you import is merged into a local **history cache**, so you can
geotag old photos any time without the phone connected — as long as some past
export covered those dates.

## Installation

1. Download or clone this repository.
2. Lightroom Classic → **File → Plug-in Manager → Add** → select the
   `PhoneGeotagger.lrplugin` folder.
3. For ADB pulls: install [Android platform-tools](https://developer.android.com/tools/releases/platform-tools),
   enable **USB debugging** on the phone (Settings → Developer options), and
   accept the authorization prompt when you first connect. If `adb` isn't on
   your PATH, set its full path in the plugin dialog.

The file-import path works with zero setup — you can always skip ADB and copy
the export JSON to your computer manually.

## The timezone model (please read once)

Your phone records locations in UTC. Your camera records wall-clock time.
The plugin needs to know which timezone your camera's clock was showing:

- **Camera's timezone setting is correct** (default): uses each photo's EXIF
  timezone offset. This is right for cameras that sync time from your phone —
  and also for cameras whose clock *and* timezone you simply never change,
  even when you travel (the two stay consistent, so the UTC math works out).
  Photos with no EXIF offset fall back to your home timezone below.
- **Clock was on home time**: ignores EXIF; converts using your home timezone
  (remembered between runs).
- **Clock was on destination time**: ignores EXIF; converts using the
  timezone you pick for this run — for trips where you set the camera clock
  to local time but didn't update its timezone setting.

**DST note:** the dropdowns are fixed UTC offsets, so pick the offset that was
in effect (e.g. UTC−07:00 for California in summer). One choice applies per
run — if a selection mixes shoots that need different settings, run the
plugin once per group.

The summary always shows the first and last matched coordinates — glance at
them before trusting a big run; a timezone mistake shows up as a location
hours of travel away.

## Supported Timeline formats

- **On-device export** (current Android): `semanticSegments` / `rawSignals`
- **Legacy Google Takeout** `Records.json`: `locations[]` with `latitudeE7`

## Matching behavior

- Track points bracketing the photo time are linearly interpolated when they
  are within the **maximum time gap** (default 15 minutes); otherwise the
  nearest point within the gap is used; otherwise the photo is left untouched
  and reported as "no match".
- Photos that already have GPS are skipped unless **Overwrite existing GPS
  coordinates** is checked.
- Coordinates are written to the Lightroom catalog only; use Lightroom's
  **Metadata → Save Metadata to File** to write them into your files/XMP.

## Development

Core logic is plain Lua 5.1 with no Lightroom dependencies, tested with
[busted](https://lunarmodules.github.io/busted/):

```sh
luarocks install busted
busted
```

The Lightroom-facing layer (`Info.lua`, `GeotagMenuItem.lua`,
`GeotagDialog.lua`, `LrExec.lua`) is kept thin and verified manually.

## Credits

- JSON parsing by [dkjson](http://dkolf.de/dkjson-lua/) (David Kolf, MIT).

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Final full-suite run**

Run: `busted`
Expected: all specs pass, `0 failures`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with install, timezone model, and dev guide"
```
