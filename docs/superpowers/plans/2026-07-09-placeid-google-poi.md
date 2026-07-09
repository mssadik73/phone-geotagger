# placeId-Based Google POI Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve each photo's place from the Timeline visit's Google `placeId` (or a Google reverse-geocode) at geotag time, write it into IPTC, make collections a pure offline pass, and make correction a Google POI search.

**Architecture:** Timeline parsing keeps visits (placeId + interval); geotag matches visit-first, resolves via Google Place Details / reverse, writes GPS + IPTC; collections read IPTC offline; correction searches Google Places. New pure modules `visit_matcher`; changed `timeline_parser`/`history_cache`/`google_geo`; the OpenStreetMap and map-picker stacks are removed.

**Tech Stack:** Lua 5.1 (Lightroom runtime), Lightroom Classic SDK, Google Places API (New) + Google Geocoding API, vendored dkjson, busted.

**Spec:** `docs/superpowers/specs/2026-07-09-placeid-google-poi-design.md`

## Global Constraints

- **Lua 5.1 compatible everywhere** (no `goto`, no `table.unpack`, no `//`).
- **Flat file layout** in `PhoneGeotagger.lrplugin/`; core modules never call Lightroom's `import` (may `require "dkjson"`).
- Place model `{ poi, city, state, country }`. IPTC write keys: `location` (POI/Sublocation), `city`, `stateProvince`, `country`. IPTC read (formatted) keys: `location`, `city`, `state`, `country`.
- Collection levels fine→coarse: `poi < city < state < country`.
- Google key lives in `prefs.google_api_key` (Plug-in Manager); geotag and correction **require** it.
- Places Place Details: `GET https://places.googleapis.com/v1/places/<place_id>`, headers `X-Goog-Api-Key`, `X-Goog-FieldMask: displayName,addressComponents`. Places Text Search: `POST https://places.googleapis.com/v1/places:searchText`, field mask `places.id,places.displayName,places.location,places.addressComponents`. Geocoding reverse: `GET https://maps.googleapis.com/maps/api/geocode/json?latlng=<lat>,<lon>&key=<key>`. Address components → `locality`/`postal_town`=city, `administrative_area_level_1`=state, `country`=country (Places uses `longText`; Geocoding `long_name`).
- Cache files: history `history-v2.json` (`{points, visits}`); resolution `resolve-v1.json` (placeId + coord keys).
- Run tests with `busted`. Commit after each passing task. Work on branch `feature/google-poi-collections`. Baseline suite **109**.

---

### Task 1: visit_matcher module

**Files:**
- Create: `PhoneGeotagger.lrplugin/visit_matcher.lua`
- Test: `spec/visit_matcher_spec.lua`

**Interfaces:**
- Produces: `visit_matcher.match(visits, utc_seconds)` → `{ place_id, lat, lon }` for the visit whose `[start_t, end_t]` contains `utc_seconds` (the one with the latest `start_t` on overlap), or `nil`. `visits` is an array of `{ start_t, end_t, place_id, lat, lon }` (unordered).

- [ ] **Step 1: Write the failing tests**

`spec/visit_matcher_spec.lua`:

```lua
local visit_matcher = require "visit_matcher"

local visits = {
  { start_t = 1000, end_t = 2000, place_id = "A", lat = 10, lon = 20 },
  { start_t = 5000, end_t = 6000, place_id = "B", lat = 30, lon = 40 },
}

describe("visit_matcher.match", function()
  it("returns the visit containing the time", function()
    local v = visit_matcher.match(visits, 1500)
    assert.equals("A", v.place_id)
    assert.equals(10, v.lat)
    assert.equals(20, v.lon)
  end)

  it("is inclusive of the interval boundaries", function()
    assert.equals("A", visit_matcher.match(visits, 1000).place_id)
    assert.equals("A", visit_matcher.match(visits, 2000).place_id)
  end)

  it("returns nil between visits", function()
    assert.is_nil(visit_matcher.match(visits, 3000))
  end)

  it("returns nil before the first and after the last", function()
    assert.is_nil(visit_matcher.match(visits, 500))
    assert.is_nil(visit_matcher.match(visits, 9000))
  end)

  it("picks the later-starting visit when intervals overlap", function()
    local overlapping = {
      { start_t = 1000, end_t = 4000, place_id = "wide", lat = 1, lon = 1 },
      { start_t = 2000, end_t = 3000, place_id = "narrow", lat = 2, lon = 2 },
    }
    assert.equals("narrow", visit_matcher.match(overlapping, 2500).place_id)
  end)

  it("returns nil for an empty visit list", function()
    assert.is_nil(visit_matcher.match({}, 1500))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/visit_matcher_spec.lua`
Expected: FAIL — `module 'visit_matcher' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/visit_matcher.lua`:

```lua
-- Finds the Timeline visit whose time interval contains a UTC timestamp.

local visit_matcher = {}

-- visits: array of { start_t, end_t, place_id, lat, lon }.
-- Returns the containing visit with the latest start_t (so a narrower nested
-- visit wins over a wider one), or nil.
function visit_matcher.match(visits, utc_seconds)
  local best
  for _, v in ipairs(visits) do
    if utc_seconds >= v.start_t and utc_seconds <= v.end_t then
      if not best or v.start_t > best.start_t then best = v end
    end
  end
  return best
end

return visit_matcher
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/visit_matcher_spec.lua`
Expected: `6 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/visit_matcher.lua spec/visit_matcher_spec.lua
git commit -m "feat: visit_matcher for Timeline visit interval lookup"
```

---

### Task 2: google_geo — add place_details + text_search, remove nearest_poi

**Files:**
- Modify: `PhoneGeotagger.lrplugin/google_geo.lua`
- Modify: `spec/google_geo_spec.lua`

**Interfaces:**
- Consumes: injected `http_get(url, headers)` (headers optional) and `http_post(url, body, headers)`; `dkjson`.
- Produces:
  - `google_geo.place_details(http_get, key, place_id)` → `{ poi, city, state, country }` or `nil, error`.
  - `google_geo.text_search(http_post, key, query, bias_lat, bias_lon)` → array of `{ place_id, poi, city, state, country, lat, lon }` (possibly empty) or `nil, error`. Location bias omitted when `bias_lat`/`bias_lon` are nil.
  - `google_geo.reverse(http_get, key, lat, lon)` → unchanged `{ city, state, country }` or `nil, error`.
  - `google_geo.nearest_poi` is removed.

- [ ] **Step 1: Replace the tests for the new functions**

In `spec/google_geo_spec.lua`, DELETE the entire `describe("google_geo.nearest_poi", ...)` block, KEEP the `describe("google_geo.reverse", ...)` block, and ADD these two blocks (reuse the file's existing `fake_post`/`fake_get` helpers; if the file's `fake_get` ignores headers, update it to `function(url, headers) calls[#calls+1] = { url = url, headers = headers }; return body end`):

```lua
local DETAILS_BODY = [[{
  "displayName": { "text": "Griffith Observatory" },
  "addressComponents": [
    { "longText": "Los Angeles", "types": ["locality"] },
    { "longText": "California", "types": ["administrative_area_level_1"] },
    { "longText": "United States", "types": ["country"] }
  ]
}]]

local SEARCH_BODY = [[{
  "places": [
    {
      "id": "ChIJ_place_1",
      "displayName": { "text": "Golden Gate Park" },
      "location": { "latitude": 37.7694, "longitude": -122.4862 },
      "addressComponents": [
        { "longText": "San Francisco", "types": ["locality"] },
        { "longText": "California", "types": ["administrative_area_level_1"] },
        { "longText": "United States", "types": ["country"] }
      ]
    }
  ]
}]]

describe("google_geo.place_details", function()
  it("parses POI and address from a Place Details response", function()
    local get = fake_get(DETAILS_BODY)
    local p = assert(google_geo.place_details(get, "KEY", "ChIJxyz"))
    assert.equals("Griffith Observatory", p.poi)
    assert.equals("Los Angeles", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
  end)

  it("requests the place path with key + field-mask headers", function()
    local get, calls = fake_get(DETAILS_BODY)
    google_geo.place_details(get, "KEY", "ChIJxyz")
    local c = calls[1]
    assert.equals("https://places.googleapis.com/v1/places/ChIJxyz", c.url)
    local hkey, hmask
    for _, h in ipairs(c.headers) do
      if h.field == "X-Goog-Api-Key" then hkey = h.value end
      if h.field == "X-Goog-FieldMask" then hmask = h.value end
    end
    assert.equals("KEY", hkey)
    assert.equals("displayName,addressComponents", hmask)
  end)

  it("errors on a Google error body", function()
    local get = fake_get('{"error": {"message": "not found"}}')
    local p, err = google_geo.place_details(get, "KEY", "bad")
    assert.is_nil(p)
    assert.matches("not found", err)
  end)
end)

describe("google_geo.text_search", function()
  it("parses results with id, poi, address, and location", function()
    local post = fake_post(SEARCH_BODY)
    local list = assert(google_geo.text_search(post, "KEY", "golden gate", 37.77, -122.42))
    assert.equals(1, #list)
    assert.equals("ChIJ_place_1", list[1].place_id)
    assert.equals("Golden Gate Park", list[1].poi)
    assert.equals("San Francisco", list[1].city)
    assert.near(37.7694, list[1].lat, 1e-6)
    assert.near(-122.4862, list[1].lon, 1e-6)
  end)

  it("sends the searchText URL, field mask, query, and location bias", function()
    local post, calls = fake_post(SEARCH_BODY)
    google_geo.text_search(post, "KEY", "golden gate", 37.77, -122.42)
    local c = calls[1]
    assert.equals("https://places.googleapis.com/v1/places:searchText", c.url)
    local body = c.body:gsub("%s", "")
    assert.matches('"textQuery":"goldengate"', body)
    assert.matches("locationBias", body)
  end)

  it("omits the bias when lat/lon are nil", function()
    local post, calls = fake_post(SEARCH_BODY)
    google_geo.text_search(post, "KEY", "eiffel tower", nil, nil)
    assert.is_nil(calls[1].body:find("locationBias", 1, true))
  end)

  it("returns an empty list when there are no results", function()
    local post = fake_post('{"places": []}')
    assert.same({}, google_geo.text_search(post, "KEY", "nowhere", nil, nil))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/google_geo_spec.lua`
Expected: FAIL — `place_details`/`text_search` not defined (and `nearest_poi` tests gone).

- [ ] **Step 3: Implement the changes**

In `PhoneGeotagger.lrplugin/google_geo.lua`: DELETE the `INCLUDED_TYPES`
constant and the entire `google_geo.nearest_poi` function. KEEP `address(...)`
and `google_geo.reverse`. Add these two functions (place them before
`return google_geo`):

```lua
-- Google Places (New) Place Details for a placeId -> { poi, city, state, country }.
function google_geo.place_details(http_get, key, place_id)
  local url = "https://places.googleapis.com/v1/places/" .. place_id
  local headers = {
    { field = "X-Goog-Api-Key", value = key },
    { field = "X-Goog-FieldMask", value = "displayName,addressComponents" },
  }
  local resp = http_get(url, headers)
  if not resp or resp == "" then return nil, "no response from Place Details" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Place Details response" end
  if doc.error then
    return nil, "Places error: " .. tostring(doc.error.message or doc.error)
  end
  local city, state, country = address(doc.addressComponents, "longText")
  return {
    poi = doc.displayName and doc.displayName.text or nil,
    city = city, state = state, country = country,
  }
end

-- Google Places (New) Text Search -> list of { place_id, poi, city, state,
-- country, lat, lon }. Location bias omitted when bias_lat/bias_lon are nil.
function google_geo.text_search(http_post, key, query, bias_lat, bias_lon)
  local req = { textQuery = query, maxResultCount = 8 }
  if bias_lat ~= nil and bias_lon ~= nil then
    req.locationBias = {
      circle = {
        center = { latitude = bias_lat, longitude = bias_lon },
        radius = 50000,
      },
    }
  end
  local headers = {
    { field = "Content-Type", value = "application/json" },
    { field = "X-Goog-Api-Key", value = key },
    { field = "X-Goog-FieldMask",
      value = "places.id,places.displayName,places.location,places.addressComponents" },
  }
  local resp = http_post("https://places.googleapis.com/v1/places:searchText",
    dkjson.encode(req), headers)
  if not resp or resp == "" then return nil, "no response from Text Search" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Text Search response" end
  if doc.error then
    return nil, "Places error: " .. tostring(doc.error.message or doc.error)
  end
  local out = {}
  for _, p in ipairs(doc.places or {}) do
    local city, state, country = address(p.addressComponents, "longText")
    out[#out + 1] = {
      place_id = p.id,
      poi = p.displayName and p.displayName.text or nil,
      city = city, state = state, country = country,
      lat = p.location and p.location.latitude or nil,
      lon = p.location and p.location.longitude or nil,
    }
  end
  return out
end
```

Also change `google_geo.reverse` to accept the injected `http_get` being called
as `http_get(url)` still (it passes no headers) — no change needed if `reverse`
already calls `http_get(url)`; confirm it does.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/google_geo_spec.lua`
Expected: all pass (reverse kept + place_details 3 + text_search 4).

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: green (109 − old nearest_poi tests + new; ≈ 110). `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/google_geo.lua spec/google_geo_spec.lua
git commit -m "feat: google_geo place_details + text_search; drop nearest_poi"
```

---

### Task 3: timeline_parser — return points and visits

**Files:**
- Modify: `PhoneGeotagger.lrplugin/timeline_parser.lua`
- Modify: `spec/timeline_parser_spec.lua`
- Modify: `spec/fixtures/ondevice_export.json`

**Interfaces:**
- Produces: `timeline_parser.parse(json_text)` → `{ points = { {t,lat,lon}, ... } (sorted), visits = { {start_t,end_t,place_id,lat,lon}, ... } }` on success; `nil, error` unchanged. Movement points come from `timelinePath` + `rawSignals` (and legacy `locations`); each `semanticSegments[].visit` produces one visit entry.

- [ ] **Step 1: Add a placeId to the visit in the fixture**

In `spec/fixtures/ondevice_export.json`, the `visit` segment's `topCandidate`
currently has only `placeLocation`. Add a `placeId`:

```json
      "visit": {
        "topCandidate": {
          "placeId": "ChIJ_fixture_place",
          "placeLocation": { "latLng": "23.8103000°, 90.4125000°" }
        }
      }
```

(Keep the segment's existing `startTime`/`endTime`.)

- [ ] **Step 2: Update the parser tests to the new shape**

In `spec/timeline_parser_spec.lua`, update the on-device test so it reads
`result.points` and adds a `result.visits` assertion. Replace the on-device
test body with:

```lua
  it("parses the on-device export format into points and visits", function()
    local r = assert(timeline_parser.parse(read_fixture("ondevice_export.json")))
    -- points: 2 timelinePath + 1 rawSignal (visit endpoints no longer duplicated as points)
    assert.equals(3, #r.points)
    assert.equals(1748750700, r.points[1].t)
    assert.near(23.7805733, r.points[1].lat, 1e-9)
    -- one visit, with its placeId and interval
    assert.equals(1, #r.visits)
    assert.equals("ChIJ_fixture_place", r.visits[1].place_id)
    assert.equals(1748754000, r.visits[1].start_t)  -- 2025-06-01T11:00:00+06:00
    assert.equals(1748757600, r.visits[1].end_t)    -- 2025-06-01T12:00:00+06:00
    assert.near(23.8103, r.visits[1].lat, 1e-9)
    assert.near(90.4125, r.visits[1].lon, 1e-9)
  end)
```

In the legacy Takeout test and every other test in the file, change the return
consumption from a bare points array to `.points` (e.g.
`local r = assert(timeline_parser.parse(...)); assert.equals(2, #r.points)`),
and the error tests still assert `nil, err`. The "geo: URI / duration offset"
test asserts on `r.points`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `busted spec/timeline_parser_spec.lua`
Expected: FAIL — parser returns a flat array; `.points`/`.visits` are nil.

- [ ] **Step 4: Update the parser**

In `PhoneGeotagger.lrplugin/timeline_parser.lua`:

Change `parse_ondevice` so visits go to a separate list and are NOT emitted as
points. Replace the `if seg.visit then ... end` block with visit collection:

```lua
    if seg.visit then
      local tc = seg.visit.topCandidate
      local lat, lon = parse_latlng(tc and tc.placeLocation and tc.placeLocation.latLng)
      local s, e = utc(seg.startTime), utc(seg.endTime)
      if lat and s and e then
        visits[#visits + 1] = {
          start_t = s, end_t = e,
          place_id = tc.placeId,
          lat = lat, lon = lon,
        }
      end
    end
```

Thread a `visits` table through: have `parse_ondevice(doc, points, visits)` and
`parse_takeout(doc, points)` (takeout has no visits). Then change the public
`parse` to build both and return the new shape:

```lua
function timeline_parser.parse(json_text)
  local doc, _, jerr = dkjson.decode(json_text)
  if type(doc) ~= "table" then
    return nil, "Not valid JSON: " .. tostring(jerr)
  end
  local points, visits = {}, {}
  if type(doc.locations) == "table" then
    parse_takeout(doc, points)
  elseif type(doc.semanticSegments) == "table" or type(doc.rawSignals) == "table" then
    parse_ondevice(doc, points, visits)
  else
    return nil, "Unrecognized file. Expected a Google Timeline on-device export "
      .. "(semanticSegments/rawSignals) or a legacy Takeout Records.json (locations)."
  end
  if #points == 0 and #visits == 0 then
    return nil, "No location points found in the file."
  end
  table.sort(points, function(a, b) return a.t < b.t end)
  return { points = points, visits = visits }
end
```

(Update `parse_ondevice`'s signature and its `rawSignals`/`timelinePath` loops to
append to the passed `points`; leave those loops otherwise unchanged.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `busted spec/timeline_parser_spec.lua`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/timeline_parser.lua spec/timeline_parser_spec.lua spec/fixtures/ondevice_export.json
git commit -m "feat: timeline_parser returns points and visits (with placeId)"
```

---

### Task 4: history_cache — store points and visits (JSON)

**Files:**
- Modify: `PhoneGeotagger.lrplugin/history_cache.lua`
- Modify: `spec/history_cache_spec.lua`

**Interfaces:**
- Consumes: `dkjson`.
- Produces:
  - `history_cache.load(path)` → `{ points = {...}, visits = {...} }` (`{points={}, visits={}}` if missing/unparseable).
  - `history_cache.merge(existing, incoming)` → merged `{ points, visits }` (points deduped by integer `t`, existing wins; visits deduped by `place_id.."@"..start_t`, existing wins; both sorted by `t`/`start_t`).
  - `history_cache.save(path, data)` → `true` or `nil, err` (tmp+rename, sandbox-safe fallback preserved).
  - `history_cache.coverage(data)` → `nil` if no points, else `{ count, first_t, last_t }` over points.

- [ ] **Step 1: Rewrite the tests**

Replace `spec/history_cache_spec.lua` with:

```lua
local history_cache = require "history_cache"

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local path = tmpdir .. "/phone_geotagger_hist_test.json"

describe("history_cache", function()
  before_each(function() os.remove(path) end)
  after_each(function() os.remove(path) end)

  it("loads empty points+visits when the file is missing", function()
    assert.same({ points = {}, visits = {} }, history_cache.load(path))
  end)

  it("saves and reloads points and visits", function()
    local data = {
      points = { { t = 100, lat = 23.78, lon = 90.27 } },
      visits = { { start_t = 100, end_t = 200, place_id = "A", lat = 1, lon = 2 } },
    }
    assert.is_true(history_cache.save(path, data))
    local loaded = history_cache.load(path)
    assert.equals(1, #loaded.points)
    assert.equals(100, loaded.points[1].t)
    assert.equals("A", loaded.visits[1].place_id)
    assert.equals(200, loaded.visits[1].end_t)
  end)

  it("merges points (existing wins) and visits (by place_id@start_t)", function()
    local existing = {
      points = { { t = 100, lat = 1, lon = 2 } },
      visits = { { start_t = 100, end_t = 200, place_id = "A", lat = 1, lon = 1 } },
    }
    local incoming = {
      points = { { t = 100, lat = 9, lon = 9 }, { t = 50, lat = 3, lon = 4 } },
      visits = {
        { start_t = 100, end_t = 200, place_id = "A", lat = 9, lon = 9 }, -- dup
        { start_t = 300, end_t = 400, place_id = "B", lat = 5, lon = 6 },
      },
    }
    local m = history_cache.merge(existing, incoming)
    assert.equals(2, #m.points)
    assert.equals(50, m.points[1].t)      -- sorted
    assert.equals(1, m.points[2].lat)     -- existing wins at t=100
    assert.equals(2, #m.visits)
    assert.equals(1, m.visits[1].lat)     -- existing A wins
    assert.equals("B", m.visits[2].place_id)
  end)

  it("reports coverage over points", function()
    assert.is_nil(history_cache.coverage({ points = {}, visits = {} }))
    local cov = history_cache.coverage({
      points = { { t = 100, lat = 1, lon = 2 }, { t = 900, lat = 3, lon = 4 } },
      visits = {},
    })
    assert.same({ count = 2, first_t = 100, last_t = 900 }, cov)
  end)

  it("load returns empty structure on unparseable file", function()
    local f = assert(io.open(path, "w")); f:write("not json"); f:close()
    assert.same({ points = {}, visits = {} }, history_cache.load(path))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/history_cache_spec.lua`
Expected: FAIL — current module is CSV/points-only.

- [ ] **Step 3: Rewrite history_cache.lua**

Replace `PhoneGeotagger.lrplugin/history_cache.lua` with:

```lua
-- Accumulated Timeline history: movement points and visits (with placeId),
-- stored as one JSON object so old photos can be geotagged from past exports.

local dkjson = require "dkjson"

local history_cache = {}

function history_cache.load(path)
  local f = io.open(path, "r")
  if not f then return { points = {}, visits = {} } end
  local text = f:read("*a")
  f:close()
  if not text then return { points = {}, visits = {} } end
  local t = dkjson.decode(text)
  if type(t) ~= "table" then return { points = {}, visits = {} } end
  return { points = t.points or {}, visits = t.visits or {} }
end

local function merge_by(existing, incoming, key_of)
  local seen, out = {}, {}
  local function absorb(list)
    for _, item in ipairs(list) do
      local k = key_of(item)
      if not seen[k] then seen[k] = true; out[#out + 1] = item end
    end
  end
  absorb(existing)
  absorb(incoming)
  return out
end

function history_cache.merge(existing, incoming)
  local points = merge_by(existing.points or {}, incoming.points or {},
    function(p) return math.floor(p.t) end)
  local visits = merge_by(existing.visits or {}, incoming.visits or {},
    function(v) return tostring(v.place_id) .. "@" .. tostring(v.start_t) end)
  table.sort(points, function(a, b) return a.t < b.t end)
  table.sort(visits, function(a, b) return a.start_t < b.start_t end)
  return { points = points, visits = visits }
end

function history_cache.save(path, data)
  local atomic = os.rename ~= nil
  local target = atomic and (path .. ".tmp") or path
  local f, err = io.open(target, "w")
  if not f then return nil, err end
  local wrote, werr = f:write(dkjson.encode(data, { indent = false }))
  f:close()
  if not wrote then
    if os.remove then os.remove(target) end
    return nil, werr
  end
  if atomic then
    if os.remove then os.remove(path) end
    local ok, rerr = os.rename(target, path)
    if not ok then return nil, rerr end
  end
  return true
end

function history_cache.coverage(data)
  local points = data.points or {}
  if #points == 0 then return nil end
  return { count = #points, first_t = points[1].t, last_t = points[#points].t }
end

return history_cache
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/history_cache_spec.lua`
Expected: `5 successes / 0 failures`

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: green (the shell files that consume history_cache aren't loaded by the
suite; they are updated in later tasks).

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/history_cache.lua spec/history_cache_spec.lua
git commit -m "feat: history_cache stores points + visits as JSON"
```

---

### Task 5: plugin_paths — new cache filenames

**Files:**
- Modify: `PhoneGeotagger.lrplugin/plugin_paths.lua`

**Interfaces:**
- Produces: `plugin_paths.cache_path()` → `.../PhoneGeotagger/history-v2.json`; `plugin_paths.resolve_cache_path()` → `.../PhoneGeotagger/resolve-v1.json`. (The old `geocode_cache_path` is renamed to `resolve_cache_path`.)

- [ ] **Step 1: Update plugin_paths.lua**

In `PhoneGeotagger.lrplugin/plugin_paths.lua`, change `cache_path` to the new
JSON history file and rename the geocode path function:

```lua
-- Accumulated Timeline history (points + visits), JSON.
function plugin_paths.cache_path()
  return LrPathUtils.child(data_dir(), "history-v2.json")
end

-- Resolution cache: placeId/coordinate -> resolved place, JSON.
function plugin_paths.resolve_cache_path()
  return LrPathUtils.child(data_dir(), "resolve-v1.json")
end
```

(Remove the old `geocode_cache_path`; the `data_dir()` helper is unchanged.)

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/plugin_paths.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/plugin_paths.lua
git commit -m "feat: plugin_paths history-v2 + resolve-v1 cache files"
```

---

### Task 6: Plug-in Manager API key field

**Files:**
- Create: `PhoneGeotagger.lrplugin/PluginInfoProvider.lua`
- Modify: `PhoneGeotagger.lrplugin/Info.lua`

**Interfaces:**
- Produces: `prefs.google_api_key`, editable in File → Plug-in Manager. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Write PluginInfoProvider.lua**

`PhoneGeotagger.lrplugin/PluginInfoProvider.lua`:

```lua
local LrView = import "LrView"
local LrPrefs = import "LrPrefs"

local provider = {}

function provider.sectionsForTopOfDialog(f, _)
  local prefs = LrPrefs.prefsForPlugin()
  return {
    {
      title = "Phone Geotagger",
      f:row {
        f:static_text { title = "Google API key:", width = 110 },
        f:edit_field {
          value = LrView.bind { key = "google_api_key", object = prefs },
          fill_horizontal = 1,
          width_in_chars = 40,
        },
      },
      f:static_text {
        title = "Required for geotagging and correction (POI names + "
          .. "geocoding). Enable the Places API (New) and the Geocoding API "
          .. "on your Google Cloud project.",
        fill_horizontal = 1,
      },
    },
  }
end

return provider
```

- [ ] **Step 2: Register it in Info.lua**

In `PhoneGeotagger.lrplugin/Info.lua`, add the top-level key (next to
`LrLibraryMenuItems`):

```lua
  LrPluginInfoProvider = "PluginInfoProvider.lua",
```

- [ ] **Step 3: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/PluginInfoProvider.lua PhoneGeotagger.lrplugin/Info.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 4: Manual test** (deferred to owner; note in report)

File → Plug-in Manager → Phone Geotagger shows a "Google API key" field that
persists across reopens.

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/PluginInfoProvider.lua PhoneGeotagger.lrplugin/Info.lua
git commit -m "feat: Google API key field in the Plug-in Manager"
```

---

### Task 7: GeotagDialog — new history shape

**Files:**
- Modify: `PhoneGeotagger.lrplugin/GeotagDialog.lua`

**Interfaces:**
- Consumes: `history_cache.load/merge/save/coverage` with the `{points, visits}` shape (Task 4); `timeline_parser.parse` returning `{points, visits}` (Task 3).
- Produces: `GeotagDialog.run(args)` unchanged externally except `args.points` becomes `args.history` (a `{points, visits}` table) and the returned settings carry `history` instead of `points`. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Update GeotagDialog.lua**

Read `PhoneGeotagger.lrplugin/GeotagDialog.lua`. Apply these changes:

1. Rename the local working variable from `points` to `history` (it now holds a
   `{points, visits}` table). In `GeotagDialog.run`, change
   `local points = args.points` to `local history = args.history`.
2. `coverage_text` takes the history table: change its calls to
   `coverage_text(history)` and its body to `history_cache.coverage(history)`
   (which already expects `{points,...}`).
3. In `absorb_file`, merge with the new shape:
   ```lua
     local parsed, err = timeline_parser.parse(text)
     if not parsed then
       LrDialogs.message("Import failed", err, "warning")
       return
     end
     history = history_cache.merge(history, parsed)
     local ok, serr = history_cache.save(args.cache_path, history)
   ```
   (`parsed` is now `{points, visits}`; `history_cache.merge` handles it.)
4. In the returned `result` table, replace `points = points` with
   `history = history` (the menu item consumes `settings.history`).

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/GeotagDialog.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/GeotagDialog.lua
git commit -m "refactor: GeotagDialog uses the points+visits history shape"
```

---

### Task 8: GeotagMenuItem — visit-first match, resolve place, write IPTC

**Files:**
- Modify (replace the pipeline): `PhoneGeotagger.lrplugin/GeotagMenuItem.lua`

**Interfaces:**
- Consumes: `history_cache.load` (`{points, visits}`), `visit_matcher.match(visits, utc)`, `matcher.match(points, utc, gap)`, `coord_round.round`, `time_resolver.resolve`, `google_geo.place_details`/`reverse`, `geo_cache.load/save`, `plugin_paths.cache_path`/`resolve_cache_path`, `GeotagDialog.run{ photo_count, history, cache_path, prefs }` → `settings.history`; Lightroom SDK (`LrHttp.get`, `LrPrefs`, `LrTasks.pcall`, `LrProgressScope`, `getRawMetadata`, `setRawMetadata`, `withWriteAccessDo`).
- Produces: the resolving geotag command. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Rewrite GeotagMenuItem.lua**

Read the current file to keep the cache-path helper and the exact `settings`
field names from `GeotagDialog` (`override_offset`, `home_offset`, `drift`,
`max_gap_sec`, `overwrite`, `precision`, `history`). Replace the file with:

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"

local history_cache = require "history_cache"
local visit_matcher = require "visit_matcher"
local matcher = require "matcher"
local coord_round = require "coord_round"
local time_resolver = require "time_resolver"
local google_geo = require "google_geo"
local geo_cache = require "geo_cache"
local plugin_paths = require "plugin_paths"
local GeotagDialog = require "GeotagDialog"

local function http_get(url, headers)
  return (LrHttp.get(url, headers))
end

LrTasks.startAsyncTask(function()
  local progress
  local ok, err = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    if catalog:getTargetPhoto() == nil then
      LrDialogs.message("Geotag from Phone Timeline",
        "Select photos in the Library grid first.", "info")
      return
    end

    local prefs = LrPrefs.prefsForPlugin()
    local key = prefs.google_api_key
    if not key or key == "" then
      LrDialogs.message("Geotag from Phone Timeline",
        "Set your Google API key in the Plug-in Manager "
        .. "(File > Plug-in Manager > Phone Geotagger) first.", "info")
      return
    end

    local photos = catalog:getTargetPhotos()
    local cpath = plugin_paths.cache_path()
    local history = history_cache.load(cpath)

    local settings = GeotagDialog.run {
      photo_count = #photos, history = history, cache_path = cpath, prefs = prefs,
    }
    if not settings then return end
    history = settings.history

    local resolve_path = plugin_paths.resolve_cache_path()
    local resolve = geo_cache.load(resolve_path)

    -- Resolve a placeId (cached).
    local function resolve_place(place_id)
      local k = "pid:" .. place_id
      local p = resolve[k]
      if not p then
        p = google_geo.place_details(http_get, key, place_id)
        if p then resolve[k] = p end
      end
      return p
    end
    -- Reverse-geocode a coordinate (cached).
    local function resolve_coord(lat, lon)
      local k = geo_cache.key(lat, lon)
      local p = resolve[k]
      if not p then
        p = google_geo.reverse(http_get, key, lat, lon)
        if p then resolve[k] = p end
      end
      return p
    end

    local stats = { skipped = 0, unmatched = 0, no_time = 0, resolved = 0 }
    local writes = {}
    progress = LrProgressScope { title = "Geotagging from phone Timeline" }
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
          local utc = time_resolver.resolve(iso, {
            override_offset = settings.override_offset,
            home_offset = settings.home_offset,
            drift = settings.drift,
          })
          if not utc then
            stats.no_time = stats.no_time + 1
          else
            local lat, lon, place
            local v = visit_matcher.match(history.visits, utc)
            if v then
              lat, lon = v.lat, v.lon
              if v.place_id then place = resolve_place(v.place_id) end
            else
              lat, lon = matcher.match(history.points, utc, settings.max_gap_sec)
              if lat then place = resolve_coord(lat, lon) end
            end
            if lat then
              lat, lon = coord_round.round(lat, lon, settings.precision)
              if place then stats.resolved = stats.resolved + 1 end
              writes[#writes + 1] = { photo = photo, lat = lat, lon = lon, place = place }
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
          local p = w.place
          if p then
            if p.country then w.photo:setRawMetadata("country", p.country) end
            if p.state then w.photo:setRawMetadata("stateProvince", p.state) end
            if p.city then w.photo:setRawMetadata("city", p.city) end
            if p.poi then w.photo:setRawMetadata("location", p.poi) end
          end
        end
      end)
    end
    geo_cache.save(resolve_path, resolve)
    progress:done()
    progress = nil

    LrDialogs.message("Geotag from Phone Timeline — done", string.format(
      "Tagged: %d (%d with a place)\nSkipped (had GPS): %d\n"
      .. "No match: %d\nNo capture time: %d",
      #writes, stats.resolved, stats.skipped, stats.unmatched, stats.no_time), "info")
  end)
  if progress then progress:done() end
  if not ok then
    LrDialogs.message("Geotag from Phone Timeline",
      "The command failed: " .. tostring(err), "critical")
  end
end)
```

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/GeotagMenuItem.lua
busted
```
Expected: `luac` clean; `busted` unchanged (109-ish).

- [ ] **Step 3: Manual test in Lightroom** (deferred to owner; note in report)

With the key set and a Timeline imported: geotag photos → photos taken at
visits get GPS + Sublocation(POI)/City/State/Country from the placeId; movement
photos get GPS + City/State/Country from reverse geocode; summary shows "N with
a place". No key → the set-key message.

- [ ] **Step 4: Commit**

```bash
git add PhoneGeotagger.lrplugin/GeotagMenuItem.lua
git commit -m "feat: geotag resolves place via visit placeId / reverse, writes IPTC"
```

---

### Task 9: LocationDialog — POI levels, drop endpoint

**Files:**
- Modify: `PhoneGeotagger.lrplugin/LocationDialog.lua`

**Interfaces:**
- Produces: `LocationDialog.run(args)` with `args = { photo_count, prefs }` → `{ set_name, primary, secondary }` or nil. Level popups list POI/City/State/Country; default primary `"poi"`, secondary `"city"`; no endpoint. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Rewrite LocationDialog.lua**

Replace the entire contents of `PhoneGeotagger.lrplugin/LocationDialog.lua` with:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local collection_name = require "collection_name"

local LocationDialog = {}

local LEVEL_ITEMS = {
  { title = "POI", value = "poi" },
  { title = "City", value = "city" },
  { title = "State / Province", value = "state" },
  { title = "Country", value = "country" },
}
local SECONDARY_ITEMS = {
  { title = "(none)", value = "none" },
  { title = "POI", value = "poi" },
  { title = "City", value = "city" },
  { title = "State / Province", value = "state" },
  { title = "Country", value = "country" },
}

function LocationDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("LocationDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.set_name = (prefs.loc_set_name and prefs.loc_set_name ~= "" and prefs.loc_set_name)
      or "Geo Locations"
    props.primary = prefs.loc_primary or "poi"
    props.secondary = prefs.loc_secondary or "city"

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format("%d photo(s) selected.", args.photo_count),
      },
      f:row {
        f:static_text { title = "Collection set name:" },
        f:edit_field { value = bind "set_name", width_in_chars = 24 },
      },
      f:row {
        f:static_text { title = "Collection name — primary:" },
        f:popup_menu { items = LEVEL_ITEMS, value = bind "primary" },
        f:static_text { title = "secondary:" },
        f:popup_menu { items = SECONDARY_ITEMS, value = bind "secondary" },
      },
    }

    while true do
      local action = LrDialogs.presentModalDialog {
        title = "Create Location Collections",
        contents = contents,
        actionVerb = "Create Collections",
      }
      if action ~= "ok" then return end
      if props.set_name == nil or props.set_name == "" then props.set_name = "Geo Locations" end
      local ferr = collection_name.format_error(props.primary, props.secondary)
      if ferr then
        LrDialogs.message("Invalid collection name format", ferr, "warning")
      else
        prefs.loc_set_name = props.set_name
        prefs.loc_primary = props.primary
        prefs.loc_secondary = props.secondary
        prefs.loc_endpoint = nil
        result = { set_name = props.set_name, primary = props.primary, secondary = props.secondary }
        return
      end
    end
  end)

  return result
end

return LocationDialog
```

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/LocationDialog.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationDialog.lua
git commit -m "refactor: LocationDialog POI levels, no endpoint"
```

---

### Task 10: LocationCollectionsMenuItem — offline IPTC read

**Files:**
- Modify (replace entirely): `PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`

**Interfaces:**
- Consumes: `collection_name.of(place, fmt)`, `LocationDialog.run{photo_count, prefs}` → `{set_name, primary, secondary}`; Lightroom SDK (`getTargetPhoto(s)`, `batchGetFormattedMetadata`, `withWriteAccessDo`, `createCollectionSet`, `createCollection`, `collection:addPhotos`, `LrProgressScope`, `LrTasks.pcall`, `LrPrefs`).
- Produces: the offline collections command. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Replace the file**

`PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`:

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local collection_name = require "collection_name"
local LocationDialog = require "LocationDialog"

local FLUSH_SIZE = 500

LrTasks.startAsyncTask(function()
  local progress
  local ok, err = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    if catalog:getTargetPhoto() == nil then
      LrDialogs.message("Create Location Collections",
        "Select the photos to organize in the Library grid first.", "info")
      return
    end
    local photos = catalog:getTargetPhotos()

    local prefs = LrPrefs.prefsForPlugin()
    local settings = LocationDialog.run { photo_count = #photos, prefs = prefs }
    if not settings then return end
    local fmt = { primary = settings.primary, secondary = settings.secondary }

    local meta = catalog:batchGetFormattedMetadata(photos,
      { "location", "city", "state", "country" })

    local set
    catalog:withWriteAccessDo("Location collections set", function()
      set = catalog:createCollectionSet(settings.set_name, nil, true)
    end)

    local colls = {}
    local pending = {}
    local pending_n = 0
    local added, unresolved = 0, 0

    local function flush()
      if pending_n == 0 then return end
      catalog:withWriteAccessDo("Add photos to location collections", function()
        for name, list in pairs(pending) do
          local coll = colls[name]
          if not coll then
            coll = catalog:createCollection(name, set, true)
            colls[name] = coll
          end
          coll:addPhotos(list)
        end
      end)
      pending = {}
      pending_n = 0
    end

    progress = LrProgressScope { title = "Building location collections" }
    progress:setCancelable(true)

    for i, photo in ipairs(photos) do
      if progress:isCanceled() then break end
      local m = meta[photo] or {}
      local place = {
        poi = m.location, city = m.city, state = m.state, country = m.country,
      }
      local name = collection_name.of(place, fmt)
      if name then
        pending[name] = pending[name] or {}
        pending[name][#pending[name] + 1] = photo
        pending_n = pending_n + 1
        added = added + 1
        if pending_n >= FLUSH_SIZE then flush() end
      else
        unresolved = unresolved + 1
      end
      progress:setPortionComplete(i, #photos)
    end

    flush()
    progress:done()
    progress = nil

    local n_colls = 0
    for _ in pairs(colls) do n_colls = n_colls + 1 end
    LrDialogs.message("Create Location Collections",
      string.format(
        "Added %d photo(s) to %d location collection(s) under \"%s\".\n"
        .. "%d had no resolved location (re-geotag them first).",
        added, n_colls, settings.set_name, unresolved), "info")
  end)
  if progress then progress:done() end
  if not ok then
    LrDialogs.message("Create Location Collections",
      "The command failed: " .. tostring(err), "critical")
  end
end)
```

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Manual test in Lightroom** (deferred to owner; note in report)

After geotagging (which wrote IPTC), select photos → Create Location
Collections → collections built offline from the IPTC place, named per the
chosen format; photos without a resolved location counted as such.

- [ ] **Step 4: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua
git commit -m "feat: offline Location Collections from IPTC place metadata"
```

---

### Task 11: CorrectDialog — Google POI search

**Files:**
- Modify (replace entirely): `PhoneGeotagger.lrplugin/CorrectDialog.lua`

**Interfaces:**
- Consumes: `google_geo.text_search(http_post, key, query, bias_lat, bias_lon)`; Lightroom SDK (`LrView`, `LrBinding`, `LrFunctionContext`, `LrDialogs`, `LrHttp.post`, `LrTasks`).
- Produces: `CorrectDialog.run(args)` with `args = { photo_count, current_lat, current_lon, key }` → `{ lat, lon, poi, city, state, country }` (the picked place) or nil. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Replace CorrectDialog.lua**

`PhoneGeotagger.lrplugin/CorrectDialog.lua`:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrTasks = import "LrTasks"

local google_geo = require "google_geo"

local CorrectDialog = {}

local function http_post(url, body, headers)
  return (LrHttp.post(url, body, headers))
end

local function fmt(lat, lon)
  return string.format("%.5f, %.5f", lat, lon)
end

-- args: { photo_count, current_lat, current_lon, key }
-- Returns { lat, lon, poi, city, state, country } or nil.
function CorrectDialog.run(args)
  local result

  LrFunctionContext.callWithContext("CorrectDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.query = ""
    props.status = "Search Google for the correct place, then pick it below."
    props.items = { { title = "(search first)", value = 0 } }
    props.choice = 0
    local hits = {} -- index -> place

    local function do_search()
      LrTasks.startAsyncTask(function()
        local list, err = google_geo.text_search(http_post, args.key, props.query,
          args.current_lat, args.current_lon)
        if not list then
          props.status = "Search failed: " .. tostring(err)
          return
        end
        if #list == 0 then
          props.status = "No places found for: " .. props.query
          props.items = { { title = "(no results)", value = 0 } }
          hits = {}
          return
        end
        hits = {}
        local items = {}
        for i, p in ipairs(list) do
          hits[i] = p
          local label = p.poi or "(unnamed)"
          if p.city then label = label .. ", " .. p.city end
          items[i] = { title = label, value = i }
        end
        props.items = items
        props.choice = 1
        props.status = string.format("%d result(s). Pick one and click Apply.", #list)
      end)
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text { title = "Current tag: " .. fmt(args.current_lat, args.current_lon) },
      f:row {
        f:edit_field { value = bind "query", width_in_chars = 30,
          placeholder_string = "Search for a place" },
        f:push_button { title = "Search", action = do_search },
      },
      f:static_text { title = bind "status", fill_horizontal = 1 },
      f:popup_menu { value = bind "choice", items = bind "items", fill_horizontal = 1 },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Correct Geotag",
      contents = contents,
      actionVerb = string.format("Apply to %d photo(s)", args.photo_count),
    }
    if action ~= "ok" then return end

    local p = hits[props.choice]
    if not p or not p.lat then
      LrDialogs.message("Correct Geotag",
        "No place was picked. Search and select a place first.", "warning")
      return
    end
    result = {
      lat = p.lat, lon = p.lon,
      poi = p.poi, city = p.city, state = p.state, country = p.country,
    }
  end)

  return result
end

return CorrectDialog
```

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/CorrectDialog.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/CorrectDialog.lua
git commit -m "feat: CorrectDialog picks a place via Google Text Search"
```

---

### Task 12: CorrectGeotagMenuItem — write picked place (GPS + IPTC)

**Files:**
- Modify: `PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua`

**Interfaces:**
- Consumes: `CorrectDialog.run{ photo_count, current_lat, current_lon, key }` → `{ lat, lon, poi, city, state, country }`; `LrPrefs`; Lightroom SDK.
- Produces: the correction command writing GPS + IPTC. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Update CorrectGeotagMenuItem.lua**

Read the current file. Apply these changes to its async body:

1. Add `local LrPrefs = import "LrPrefs"` to the imports; remove any
   `require "candidate_finder"`, `require "history_cache"`, and
   `require "plugin_paths"` that are only used for the old history-candidate
   path (keep imports still needed).
2. After the empty-selection and first-photo-GPS guards, add the key check and
   drop the candidate/cache loading:
   ```lua
     local prefs = LrPrefs.prefsForPlugin()
     local key = prefs.google_api_key
     if not key or key == "" then
       LrDialogs.message("Correct Geotag",
         "Set your Google API key in the Plug-in Manager "
         .. "(File > Plug-in Manager > Phone Geotagger) first.", "info")
       return
     end
   ```
3. Change the dialog call to the new signature and result:
   ```lua
     local result = CorrectDialog.run {
       photo_count = #photos,
       current_lat = gps.latitude,
       current_lon = gps.longitude,
       key = key,
     }
     if not result then return end
   ```
4. Change the write block to write GPS + IPTC for every selected photo:
   ```lua
     catalog:withWriteAccessDo("Correct geotag", function()
       for _, photo in ipairs(photos) do
         photo:setRawMetadata("gps", { latitude = result.lat, longitude = result.lon })
         if result.country then photo:setRawMetadata("country", result.country) end
         if result.state then photo:setRawMetadata("stateProvince", result.state) end
         if result.city then photo:setRawMetadata("city", result.city) end
         if result.poi then photo:setRawMetadata("location", result.poi) end
       end
     end)
     LrDialogs.message("Correct Geotag", string.format(
       "%d photo(s) re-tagged to %s (%.5f, %.5f).",
       #photos, result.poi or "the selected place", result.lat, result.lon), "info")
   ```

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Manual test in Lightroom** (deferred to owner; note in report)

Select photos → Correct Geotag of Selection → search a place → pick → Apply →
photos get the place's GPS + Sublocation/City/State/Country. No key → the
message.

- [ ] **Step 4: Commit**

```bash
git add PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua
git commit -m "feat: correction writes the picked Google place (GPS + IPTC)"
```

---

### Task 13: Remove the OpenStreetMap client and parser

**Files:**
- Delete: `PhoneGeotagger.lrplugin/geocode_client.lua`, `spec/geocode_client_spec.lua`, `PhoneGeotagger.lrplugin/place_extract.lua`, `spec/place_extract_spec.lua`

- [ ] **Step 1: Confirm no references remain**

Run:
```bash
grep -rn "geocode_client\|place_extract" PhoneGeotagger.lrplugin spec
```
Expected: only the four files reference their own names. If any other file
requires them, STOP — an earlier task was incomplete.

- [ ] **Step 2: Delete**

```bash
git rm PhoneGeotagger.lrplugin/geocode_client.lua spec/geocode_client_spec.lua \
       PhoneGeotagger.lrplugin/place_extract.lua spec/place_extract_spec.lua
```

- [ ] **Step 3: Run the full suite**

Run: `busted`
Expected: green (drops the geocode_client + place_extract test counts).

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: remove OpenStreetMap client and parser"
```

---

### Task 14: Remove the map-picker stack

**Files:**
- Delete: `PhoneGeotagger.lrplugin/mappicker.html`, `PhoneGeotagger.lrplugin/leaflet.js`, `PhoneGeotagger.lrplugin/leaflet.css`, `PhoneGeotagger.lrplugin/clipboard.lua`, `spec/clipboard_spec.lua`, `PhoneGeotagger.lrplugin/coord_parse.lua`, `spec/coord_parse_spec.lua`, `PhoneGeotagger.lrplugin/candidate_finder.lua`, `spec/candidate_finder_spec.lua`, `PhoneGeotagger.lrplugin/LrExec.lua`

- [ ] **Step 1: Confirm no references remain**

Run:
```bash
grep -rn "clipboard\|coord_parse\|candidate_finder\|LrExec\|mappicker\|leaflet" PhoneGeotagger.lrplugin spec
```
Expected: only the files being deleted reference their own names — no
`require "clipboard"`, `require "coord_parse"`, `require "candidate_finder"`,
`require "LrExec"` in any surviving file (CorrectDialog was rewritten in Task 11;
CorrectGeotagMenuItem in Task 12). If any survivor references them, STOP.

- [ ] **Step 2: Delete**

```bash
git rm PhoneGeotagger.lrplugin/mappicker.html PhoneGeotagger.lrplugin/leaflet.js \
       PhoneGeotagger.lrplugin/leaflet.css PhoneGeotagger.lrplugin/clipboard.lua \
       spec/clipboard_spec.lua PhoneGeotagger.lrplugin/coord_parse.lua \
       spec/coord_parse_spec.lua PhoneGeotagger.lrplugin/candidate_finder.lua \
       spec/candidate_finder_spec.lua PhoneGeotagger.lrplugin/LrExec.lua
```

- [ ] **Step 3: Run the full suite**

Run: `busted`
Expected: green (drops clipboard + coord_parse + candidate_finder test counts).

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: remove the Leaflet map-picker + clipboard stack"
```

---

### Task 15: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the affected sections**

In `README.md`:

1. In "Getting the Timeline file to your computer" / setup, add a one-time
   Google key step near the top of usage:
   ```markdown
   **One-time setup:** create a Google Cloud project, enable the **Places API
   (New)** and the **Geocoding API**, create an API key, and paste it into
   **File → Plug-in Manager → Phone Geotagger → Google API key**. Geotagging
   and correcting both resolve place names through Google (these are billable
   APIs; results are cached so each place is looked up once).
   ```

2. Replace the "Correcting a wrong geotag" section body (keep the heading) with:
   ```markdown
   Google Timeline sometimes tags a photo to a nearby-but-wrong place. To fix a
   group:

   1. Select one photo with the bad tag and run **Library → Plug-in Extras →
      Find Photos With This Geotag** to select every photo within 25 m. Deselect
      any that don't belong.
   2. Run **Correct Geotag of Selection...**, type the correct place, click
      **Search**, pick it from the Google results, and click **Apply**. The
      place's coordinate and its name (Sublocation / City / State / Country) are
      written to every selected photo.
   ```

3. Replace the "Organizing photos into location collections" section body (keep
   the heading) with:
   ```markdown
   Geotagging writes each photo's place (POI, City, State, Country) into its
   IPTC metadata. This command turns that into collections — entirely offline,
   no API calls.

   1. Select geotagged photos and run **Library → Plug-in Extras → Create
      Location Collections...**.
   2. Choose the **collection name format** (primary + optional secondary of
      POI / City / State / Country; default `POI, City`).
   3. Each photo is added to a collection named from its stored place (e.g.
      `Griffith Observatory, Los Angeles`), all under a **Geo Locations** set.

   These are regular collections (a snapshot), so re-run after geotagging more
   photos. Photos geotagged before place resolution existed have no stored place
   — re-geotag them to populate it.
   ```

4. In "Credits", ensure the geocoding line reads:
   `- Place names and geocoding by [Google Maps Platform](https://developers.google.com/maps).`
   and remove any OpenStreetMap/Leaflet/Nominatim credit lines.

- [ ] **Step 2: Final full-suite run**

Run: `busted`
Expected: all pass, `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: Google placeId POI resolution, correction search, offline collections"
```
