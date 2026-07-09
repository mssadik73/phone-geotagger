# Location Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Create Location Collections..." command that reverse-geocodes selected photos' GPS into IPTC place-name fields and builds auto-updating Lightroom Smart Collections keyed on those names.

**Architecture:** Four new Lightroom-independent core modules (`geocode_client`, `place_extract`, `geo_cache`, `smartcoll_rules`) with busted unit tests, plus a Lightroom shell (a dialog, a menu command that calls OpenStreetMap Nominatim via `LrHttp`, writes IPTC fields, and creates smart collections). Follows the existing plugin's conventions exactly.

**Tech Stack:** Lua 5.1 (Lightroom runtime), Lightroom Classic SDK, OpenStreetMap Nominatim reverse geocoding, vendored dkjson, busted for tests.

**Spec:** `docs/superpowers/specs/2026-07-09-location-collections-design.md`

## Global Constraints

- **Lua 5.1 compatibility everywhere** (no `goto`, no `table.unpack`, no `//`). For version-sensitive math use the existing shim pattern; this feature uses no trig.
- **Flat file layout inside `PhoneGeotagger.lrplugin/`** — Lua `require` resolves only the plugin root; no subdirectories.
- **Core modules never call Lightroom's `import`** — standard Lua only: `geocode_client.lua`, `place_extract.lua`, `geo_cache.lua`, `smartcoll_rules.lua` (they may `require "dkjson"`, which is pure Lua). Lightroom-dependent files: `LocationDialog.lua`, `LocationCollectionsMenuItem.lua`, `plugin_paths.lua`, `Info.lua`.
- **GPS metadata from Lightroom** is a table `{ latitude = number, longitude = number }`. IPTC write keys (via `photo:setRawMetadata`): `country`, `stateProvince`, `city`, `location` (Sublocation).
- **Smart-collection criteria strings are the #1 verification risk** (cannot be checked without Lightroom): this plan uses `criteria = "location"` (Sublocation) and `criteria = "city"` with `operation = "=="` and top-level `combine = "intersect"`. These live ONLY in `smartcoll_rules.lua`, so if a string needs correcting after the manual Lightroom test, it is a one-file change. The manual test MUST confirm the created smart collections actually populate.
- Menu title exactly: `Create Location Collections...`. Default collection-set name `Geo Locations`. Default endpoint `https://nominatim.openstreetmap.org/reverse`. User-Agent `PhoneGeotagger/0.1 (github.com/mssadik73/phone-geotagger)`. Throttle **1.1 s between network lookups** (cache hits are not throttled).
- Run tests with `busted` from the repo root. Commit after every passing task. Work on branch `feature/location-collections`.
- Baseline suite is **69 passing**. New core-module tests add to it; Lightroom-shell tasks must not reduce it.

---

### Task 1: place_extract module

**Files:**
- Create: `PhoneGeotagger.lrplugin/place_extract.lua`
- Test: `spec/place_extract_spec.lua`

**Interfaces:**
- Produces: `place_extract.extract(address)` → `{ country, state, city, sublocation }` (each field a string or nil). `address` is a Nominatim `address` object. `city` uses the first present of city/town/village/municipality; `sublocation` uses the first present of neighbourhood/suburb/quarter/city_district, falling back to `city`. Non-table input → `{}`.

- [ ] **Step 1: Write the failing tests**

`spec/place_extract_spec.lua`:

```lua
local place_extract = require "place_extract"

describe("place_extract.extract", function()
  it("picks neighbourhood as sublocation and city", function()
    local p = place_extract.extract({
      neighbourhood = "Venice Beach", suburb = "Venice",
      city = "Los Angeles", state = "California", country = "United States",
    })
    assert.equals("Venice Beach", p.sublocation)
    assert.equals("Los Angeles", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
  end)

  it("falls back through the neighbourhood chain to suburb", function()
    local p = place_extract.extract({ suburb = "Hollywood", city = "Los Angeles" })
    assert.equals("Hollywood", p.sublocation)
  end)

  it("falls back to city/town/village for both city and sublocation", function()
    local p = place_extract.extract({ village = "Lone Pine", state = "California" })
    assert.equals("Lone Pine", p.city)
    assert.equals("Lone Pine", p.sublocation)
  end)

  it("leaves city nil but keeps sublocation when only a neighbourhood exists", function()
    local p = place_extract.extract({ neighbourhood = "Downtown", country = "X" })
    assert.equals("Downtown", p.sublocation)
    assert.is_nil(p.city)
  end)

  it("preserves non-ASCII names", function()
    local p = place_extract.extract({ suburb = "Fenerbahçe", city = "İstanbul" })
    assert.equals("Fenerbahçe", p.sublocation)
    assert.equals("İstanbul", p.city)
  end)

  it("returns an empty table for non-table input", function()
    assert.same({}, place_extract.extract(nil))
  end)

  it("ignores empty-string fields", function()
    local p = place_extract.extract({ neighbourhood = "", suburb = "Venice", city = "" })
    assert.equals("Venice", p.sublocation)
    assert.is_nil(p.city)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/place_extract_spec.lua`
Expected: FAIL — `module 'place_extract' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/place_extract.lua`:

```lua
-- Extracts human-readable place names from a Nominatim `address` object.

local place_extract = {}

local function first(t, keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    if v ~= nil and v ~= "" then return v end
  end
  return nil
end

-- Returns { country, state, city, sublocation } with nil for absent fields.
function place_extract.extract(address)
  if type(address) ~= "table" then return {} end
  local city = first(address, { "city", "town", "village", "municipality" })
  local sub = first(address, { "neighbourhood", "suburb", "quarter", "city_district" })
    or city
  return {
    country = (address.country ~= "" and address.country) or nil,
    state = (address.state ~= "" and address.state) or nil,
    city = city,
    sublocation = sub,
  }
end

return place_extract
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/place_extract_spec.lua`
Expected: `7 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/place_extract.lua spec/place_extract_spec.lua
git commit -m "feat: place_extract for Nominatim address parsing"
```

---

### Task 2: geocode_client module

**Files:**
- Create: `PhoneGeotagger.lrplugin/geocode_client.lua`
- Test: `spec/geocode_client_spec.lua`

**Interfaces:**
- Consumes: `dkjson.decode` (vendored, pure Lua).
- Produces:
  - `geocode_client.reverse_url(endpoint, lat, lon)` → the Nominatim reverse URL string.
  - `geocode_client.reverse(http_get, endpoint, lat, lon)` → the decoded `address` table on success; `nil, error_message` on empty/invalid response, a Nominatim `error` field, or a missing `address`. `http_get(url) → body_string` is injected (real one wraps `LrHttp.get`; tests use a fake).

- [ ] **Step 1: Write the failing tests**

`spec/geocode_client_spec.lua`:

```lua
local geocode_client = require "geocode_client"

local function fake_get(body)
  local calls = {}
  return function(url) calls[#calls + 1] = url; return body end, calls
end

describe("geocode_client.reverse_url", function()
  it("builds the Nominatim reverse URL", function()
    local url = geocode_client.reverse_url(
      "https://nominatim.openstreetmap.org/reverse", 34.0, -118.5)
    assert.equals(
      "https://nominatim.openstreetmap.org/reverse?format=jsonv2"
        .. "&lat=34.0000000&lon=-118.5000000&zoom=18&addressdetails=1",
      url)
  end)
end)

describe("geocode_client.reverse", function()
  it("returns the address table from a good response", function()
    local body = '{"address":{"suburb":"Venice","city":"Los Angeles"}}'
    local get, calls = fake_get(body)
    local addr = assert(geocode_client.reverse(get, "https://x/reverse", 34, -118))
    assert.equals("Venice", addr.suburb)
    assert.equals("Los Angeles", addr.city)
    assert.equals(
      "https://x/reverse?format=jsonv2&lat=34.0000000&lon=-118.0000000"
        .. "&zoom=18&addressdetails=1",
      calls[1])
  end)

  it("errors on an empty body", function()
    local get = fake_get("")
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.is_string(err)
  end)

  it("errors on invalid JSON", function()
    local get = fake_get("<html>rate limited</html>")
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.is_string(err)
  end)

  it("errors when Nominatim reports an error field", function()
    local get = fake_get('{"error":"Unable to geocode"}')
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.matches("Unable to geocode", err)
  end)

  it("errors when there is no address", function()
    local get = fake_get('{"lat":"0","lon":"0"}')
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.is_string(err)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/geocode_client_spec.lua`
Expected: FAIL — `module 'geocode_client' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/geocode_client.lua`:

```lua
-- Builds and interprets Nominatim reverse-geocode requests. HTTP is injected
-- (http_get) so this module stays Lightroom-free and unit-testable.

local dkjson = require "dkjson"

local geocode_client = {}

function geocode_client.reverse_url(endpoint, lat, lon)
  return string.format(
    "%s?format=jsonv2&lat=%.7f&lon=%.7f&zoom=18&addressdetails=1",
    endpoint, lat, lon)
end

-- http_get: function(url) -> body_string
-- Returns the decoded `address` table, or nil, error_message.
function geocode_client.reverse(http_get, endpoint, lat, lon)
  local body = http_get(geocode_client.reverse_url(endpoint, lat, lon))
  if not body or body == "" then
    return nil, "no response from geocoder"
  end
  local doc = dkjson.decode(body)
  if type(doc) ~= "table" then
    return nil, "invalid geocoder response"
  end
  if doc.error then
    return nil, "geocoder error: " .. tostring(doc.error)
  end
  if type(doc.address) ~= "table" then
    return nil, "no address in geocoder response"
  end
  return doc.address
end

return geocode_client
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/geocode_client_spec.lua`
Expected: `6 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/geocode_client.lua spec/geocode_client_spec.lua
git commit -m "feat: geocode_client for Nominatim reverse geocoding"
```

---

### Task 3: geo_cache module

**Files:**
- Create: `PhoneGeotagger.lrplugin/geo_cache.lua`
- Test: `spec/geo_cache_spec.lua`

**Interfaces:**
- Consumes: `dkjson` (vendored).
- Produces:
  - `geo_cache.key(lat, lon)` → `"%.4f,%.4f"` string key (~11 m buckets).
  - `geo_cache.load(path)` → table (`{}` if the file is missing or unparseable).
  - `geo_cache.get(cache, lat, lon)` → the stored place table or nil.
  - `geo_cache.put(cache, lat, lon, place)` → mutates `cache`, stores `place` under the key.
  - `geo_cache.save(path, cache)` → `true` or `nil, error_message` (tmp-then-rename).

- [ ] **Step 1: Write the failing tests**

`spec/geo_cache_spec.lua`:

```lua
local geo_cache = require "geo_cache"

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local path = tmpdir .. "/phone_geotagger_geocode_test.json"

describe("geo_cache", function()
  before_each(function() os.remove(path) end)
  after_each(function() os.remove(path) end)

  it("rounds the key to 4 decimals", function()
    assert.equals("34.0500,-118.2400", geo_cache.key(34.050012, -118.239987))
  end)

  it("returns an empty table when the file is missing", function()
    assert.same({}, geo_cache.load(path))
  end)

  it("puts and gets by rounded coordinate", function()
    local cache = {}
    geo_cache.put(cache, 34.05, -118.24, { city = "Los Angeles", sublocation = "DTLA" })
    local p = geo_cache.get(cache, 34.050004, -118.239996) -- same 4-decimal bucket
    assert.equals("Los Angeles", p.city)
    assert.equals("DTLA", p.sublocation)
  end)

  it("saves and reloads, preserving non-ASCII", function()
    local cache = {}
    geo_cache.put(cache, 41.0, 29.0, { city = "İstanbul", sublocation = "Fenerbahçe" })
    assert.is_true(geo_cache.save(path, cache))
    local loaded = geo_cache.load(path)
    local p = geo_cache.get(loaded, 41.0, 29.0)
    assert.equals("İstanbul", p.city)
    assert.equals("Fenerbahçe", p.sublocation)
  end)

  it("load returns empty table on unparseable file", function()
    local f = assert(io.open(path, "w")); f:write("not json"); f:close()
    assert.same({}, geo_cache.load(path))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/geo_cache_spec.lua`
Expected: FAIL — `module 'geo_cache' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/geo_cache.lua`:

```lua
-- Persistent coordinate -> resolved-place cache, so shared locations and
-- repeat runs cost no geocoder requests. Stored as a single JSON object.

local dkjson = require "dkjson"

local geo_cache = {}

function geo_cache.key(lat, lon)
  return string.format("%.4f,%.4f", lat, lon)
end

function geo_cache.load(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local t = dkjson.decode(text)
  if type(t) ~= "table" then return {} end
  return t
end

function geo_cache.get(cache, lat, lon)
  return cache[geo_cache.key(lat, lon)]
end

function geo_cache.put(cache, lat, lon, place)
  cache[geo_cache.key(lat, lon)] = place
end

-- Writes path..".tmp" then renames, so a crash can't truncate the cache.
function geo_cache.save(path, cache)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  f:write(dkjson.encode(cache, { indent = false }))
  f:close()
  os.remove(path) -- Windows os.rename refuses to overwrite
  local ok, rerr = os.rename(tmp, path)
  if not ok then return nil, rerr end
  return true
end

return geo_cache
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/geo_cache_spec.lua`
Expected: `5 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/geo_cache.lua spec/geo_cache_spec.lua
git commit -m "feat: geo_cache persistent coordinate-to-place cache"
```

---

### Task 4: smartcoll_rules module

**Files:**
- Create: `PhoneGeotagger.lrplugin/smartcoll_rules.lua`
- Test: `spec/smartcoll_rules_spec.lua`

**Interfaces:**
- Produces:
  - `smartcoll_rules.build(sublocation, city)` → a Lightroom smart-collection search-description table: `{ combine = "intersect", { criteria = "location", operation = "==", value = sublocation }, [ { criteria = "city", operation = "==", value = city } ] }`. The city criterion is omitted when `city` is nil/empty.
  - `smartcoll_rules.names(place_pairs)` → given a list of `{ sublocation, city }`, returns a parallel list of `{ sublocation, city, name }` where `name` is the sublocation, disambiguated to `"<sublocation> (<city>)"` only when the same sublocation appears for more than one city.

- [ ] **Step 1: Write the failing tests**

`spec/smartcoll_rules_spec.lua`:

```lua
local smartcoll_rules = require "smartcoll_rules"

describe("smartcoll_rules.build", function()
  it("builds a compound Sublocation AND City rule", function()
    local d = smartcoll_rules.build("Venice Beach", "Los Angeles")
    assert.equals("intersect", d.combine)
    assert.equals(2, #d)
    assert.same({ criteria = "location", operation = "==", value = "Venice Beach" }, d[1])
    assert.same({ criteria = "city", operation = "==", value = "Los Angeles" }, d[2])
  end)

  it("omits the city criterion when city is nil", function()
    local d = smartcoll_rules.build("Downtown", nil)
    assert.equals(1, #d)
    assert.same({ criteria = "location", operation = "==", value = "Downtown" }, d[1])
  end)

  it("omits the city criterion when city is empty", function()
    local d = smartcoll_rules.build("Downtown", "")
    assert.equals(1, #d)
  end)
end)

describe("smartcoll_rules.names", function()
  it("uses the bare sublocation when it is unique", function()
    local out = smartcoll_rules.names({
      { sublocation = "Venice Beach", city = "Los Angeles" },
      { sublocation = "Hollywood", city = "Los Angeles" },
    })
    assert.equals("Venice Beach", out[1].name)
    assert.equals("Hollywood", out[2].name)
  end)

  it("disambiguates a sublocation shared by two cities", function()
    local out = smartcoll_rules.names({
      { sublocation = "Downtown", city = "Los Angeles" },
      { sublocation = "Downtown", city = "San Diego" },
    })
    assert.equals("Downtown (Los Angeles)", out[1].name)
    assert.equals("Downtown (San Diego)", out[2].name)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/smartcoll_rules_spec.lua`
Expected: FAIL — `module 'smartcoll_rules' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/smartcoll_rules.lua`:

```lua
-- Builds Lightroom smart-collection search descriptions and display names for
-- reverse-geocoded places. The criteria strings ("location" = IPTC
-- Sublocation, "city") live ONLY here — the single place to correct if the
-- Lightroom manual test shows a collection not populating.

local smartcoll_rules = {}

-- Returns a Lightroom smart-collection searchDescription table.
function smartcoll_rules.build(sublocation, city)
  local desc = { combine = "intersect" }
  desc[#desc + 1] = { criteria = "location", operation = "==", value = sublocation }
  if city ~= nil and city ~= "" then
    desc[#desc + 1] = { criteria = "city", operation = "==", value = city }
  end
  return desc
end

-- Given { {sublocation, city}, ... }, returns { {sublocation, city, name}, ... }
-- disambiguating a sublocation shared across cities as "<sub> (<city>)".
function smartcoll_rules.names(place_pairs)
  local cities_for = {}
  for _, p in ipairs(place_pairs) do
    cities_for[p.sublocation] = cities_for[p.sublocation] or {}
    if p.city and p.city ~= "" then
      cities_for[p.sublocation][p.city] = true
    end
  end
  local out = {}
  for i, p in ipairs(place_pairs) do
    local count = 0
    for _ in pairs(cities_for[p.sublocation]) do count = count + 1 end
    local name = p.sublocation
    if count > 1 and p.city and p.city ~= "" then
      name = p.sublocation .. " (" .. p.city .. ")"
    end
    out[i] = { sublocation = p.sublocation, city = p.city, name = name }
  end
  return out
end

return smartcoll_rules
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/smartcoll_rules_spec.lua`
Expected: `5 successes / 0 failures`

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: all pass (69 baseline + 23 new = 92), `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/smartcoll_rules.lua spec/smartcoll_rules_spec.lua
git commit -m "feat: smartcoll_rules for smart-collection descriptions and names"
```

---

### Task 5: LocationDialog module

**Files:**
- Create: `PhoneGeotagger.lrplugin/LocationDialog.lua`

**Interfaces:**
- Produces: `LocationDialog.run(args)` with `args = { photo_count, unique_count, prefs }` → settings table `{ set_name, overwrite, endpoint }` or `nil` on cancel. Persists `set_name`, `overwrite`, `endpoint` into `prefs`. Runs only in Lightroom — no busted test; syntax-checked with `luac -p`.

- [ ] **Step 1: Write LocationDialog.lua**

`PhoneGeotagger.lrplugin/LocationDialog.lua`:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local LocationDialog = {}

-- args: { photo_count, unique_count, prefs }
-- Returns { set_name, overwrite, endpoint } or nil on cancel.
function LocationDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("LocationDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.set_name = prefs.loc_set_name or "Geo Locations"
    props.overwrite = prefs.loc_overwrite or false
    props.endpoint = prefs.loc_endpoint or "https://nominatim.openstreetmap.org/reverse"

    local est = math.ceil(args.unique_count * 1.1)
    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format(
          "%d photo(s), %d unique location(s) to look up (up to ~%d s on first run).",
          args.photo_count, args.unique_count, est),
      },
      f:row {
        f:static_text { title = "Collection set name:" },
        f:edit_field { value = bind "set_name", width_in_chars = 24 },
      },
      f:row {
        f:static_text { title = "Geocoder endpoint:" },
        f:edit_field { value = bind "endpoint", fill_horizontal = 1 },
      },
      f:checkbox {
        title = "Overwrite existing location metadata",
        value = bind "overwrite",
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Create Location Collections",
      contents = contents,
      actionVerb = "Create Collections",
    }
    if action ~= "ok" then return end

    prefs.loc_set_name = props.set_name
    prefs.loc_overwrite = props.overwrite and true or false
    prefs.loc_endpoint = props.endpoint

    result = {
      set_name = props.set_name,
      overwrite = props.overwrite and true or false,
      endpoint = props.endpoint,
    }
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
Expected: `luac` clean; `busted` still 92 green (the suite doesn't load this file).

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationDialog.lua
git commit -m "feat: Location Collections run dialog"
```

---

### Task 6: LocationCollectionsMenuItem command + plugin_paths + Info.lua

**Files:**
- Modify: `PhoneGeotagger.lrplugin/plugin_paths.lua` (add `geocode_cache_path`, share a private data-dir helper)
- Create: `PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`
- Modify: `PhoneGeotagger.lrplugin/Info.lua` (add the fourth menu entry)

**Interfaces:**
- Consumes: `geocode_client.reverse` (Task 2), `place_extract.extract` (Task 1), `geo_cache.*` (Task 3), `smartcoll_rules.build`/`smartcoll_rules.names` (Task 4), `LocationDialog.run` (Task 5); Lightroom SDK (`catalog:getTargetPhoto`, `getTargetPhotos`, `batchGetRawMetadata`, `withWriteAccessDo`, `setRawMetadata`, `createCollectionSet`, `createSmartCollection`, `LrHttp.get`, `LrProgressScope`, `LrTasks.sleep`).
- Produces: the complete user-facing feature. Runs only in Lightroom — no busted test; syntax-checked with `luac -p`.

- [ ] **Step 1: Refactor plugin_paths.lua to add the geocode cache path**

Replace the entire contents of `PhoneGeotagger.lrplugin/plugin_paths.lua` with (this preserves `cache_path()`'s exact result — `history.csv` in the same directory — so v1/v2 are unaffected):

```lua
-- Shared filesystem paths for the plugin (Lightroom-dependent).

local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local plugin_paths = {}

local function data_dir()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return dir
end

-- Absolute path to the accumulated GPS history cache CSV.
function plugin_paths.cache_path()
  return LrPathUtils.child(data_dir(), "history.csv")
end

-- Absolute path to the reverse-geocode (coordinate -> place) cache JSON.
function plugin_paths.geocode_cache_path()
  return LrPathUtils.child(data_dir(), "geocode.json")
end

return plugin_paths
```

- [ ] **Step 2: Add the menu entry to Info.lua**

In `PhoneGeotagger.lrplugin/Info.lua`, add a fourth `LrLibraryMenuItems` entry after the "Correct Geotag of Selection..." one:

```lua
    {
      title = "Create Location Collections...",
      file = "LocationCollectionsMenuItem.lua",
    },
```

- [ ] **Step 3: Write LocationCollectionsMenuItem.lua**

`PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`:

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local geocode_client = require "geocode_client"
local place_extract = require "place_extract"
local geo_cache = require "geo_cache"
local smartcoll_rules = require "smartcoll_rules"
local plugin_paths = require "plugin_paths"
local LocationDialog = require "LocationDialog"

local USER_AGENT = "PhoneGeotagger/0.1 (github.com/mssadik73/phone-geotagger)"

local function http_get(url)
  local body = LrHttp.get(url, { { field = "User-Agent", value = USER_AGENT } })
  return body
end

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  if catalog:getTargetPhoto() == nil then
    LrDialogs.message("Create Location Collections",
      "Select the photos to organize in the Library grid first.", "info")
    return
  end
  local photos = catalog:getTargetPhotos()
  local meta = catalog:batchGetRawMetadata(photos, { "gps", "city", "location" })

  -- Collect GPS photos and the unique coordinate buckets among them.
  local gps_photos = {}
  local unique = {}      -- key -> { lat, lon }
  for _, photo in ipairs(photos) do
    local m = meta[photo]
    local g = m and m.gps
    if g and g.latitude and g.longitude then
      gps_photos[#gps_photos + 1] = photo
      local k = geo_cache.key(g.latitude, g.longitude)
      if not unique[k] then unique[k] = { lat = g.latitude, lon = g.longitude } end
    end
  end
  if #gps_photos == 0 then
    LrDialogs.message("Create Location Collections",
      "None of the selected photos have GPS coordinates.", "info")
    return
  end

  local unique_count = 0
  for _ in pairs(unique) do unique_count = unique_count + 1 end

  local prefs = LrPrefs.prefsForPlugin()
  local settings = LocationDialog.run {
    photo_count = #gps_photos, unique_count = unique_count, prefs = prefs,
  }
  if not settings then return end

  -- Resolve each unique coordinate (cache first, else throttled network).
  local cache = geo_cache.load(plugin_paths.geocode_cache_path())
  local progress = LrProgressScope { title = "Looking up locations" }
  progress:setCancelable(true)
  local unresolved = 0
  local done = 0
  for k, coord in pairs(unique) do
    if progress:isCanceled() then break end
    local place = geo_cache.get(cache, coord.lat, coord.lon)
    if not place then
      local addr = geocode_client.reverse(http_get, settings.endpoint, coord.lat, coord.lon)
      place = addr and place_extract.extract(addr) or {}
      geo_cache.put(cache, coord.lat, coord.lon, place)
      LrTasks.sleep(1.1) -- Nominatim: <= 1 req/sec, only on a real lookup
    end
    if not (place.sublocation or place.city) then unresolved = unresolved + 1 end
    done = done + 1
    progress:setPortionComplete(done, unique_count)
  end
  progress:done()
  geo_cache.save(plugin_paths.geocode_cache_path(), cache)

  -- Write IPTC fields; collect distinct (sublocation, city) pairs.
  local tagged, skipped = 0, 0
  local pair_seen, pairs_list = {}, {}
  catalog:withWriteAccessDo("Write location metadata", function()
    for _, photo in ipairs(gps_photos) do
      local m = meta[photo]
      local g = m.gps
      local place = geo_cache.get(cache, g.latitude, g.longitude)
      local has_existing = (m.city and m.city ~= "") or (m.location and m.location ~= "")
      if place and place.sublocation and (settings.overwrite or not has_existing) then
        if place.country then photo:setRawMetadata("country", place.country) end
        if place.state then photo:setRawMetadata("stateProvince", place.state) end
        if place.city then photo:setRawMetadata("city", place.city) end
        photo:setRawMetadata("location", place.sublocation)
        tagged = tagged + 1
        local pk = place.sublocation .. "\0" .. (place.city or "")
        if not pair_seen[pk] then
          pair_seen[pk] = true
          pairs_list[#pairs_list + 1] =
            { sublocation = place.sublocation, city = place.city }
        end
      elseif has_existing and not settings.overwrite then
        skipped = skipped + 1
      end
    end
  end)

  -- Create / refresh the smart-collection set and members.
  local named = smartcoll_rules.names(pairs_list)
  local created = 0
  catalog:withWriteAccessDo("Create location collections", function()
    local set = catalog:createCollectionSet(settings.set_name, nil, true)
    for _, p in ipairs(named) do
      catalog:createSmartCollection(p.name, smartcoll_rules.build(p.sublocation, p.city),
        set, true)
      created = created + 1
    end
  end)

  LrDialogs.message("Create Location Collections",
    string.format(
      "Tagged %d photo(s), skipped %d (already had a location), %d unresolved.\n"
      .. "%d Smart Collection(s) under \"%s\".",
      tagged, skipped, unresolved, created, settings.set_name), "info")
end)
```

- [ ] **Step 4: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/plugin_paths.lua
luac -p PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua
luac -p PhoneGeotagger.lrplugin/Info.lua
busted
```
Expected: all `luac` clean; `busted` still 92 green.

- [ ] **Step 5: Manual test in Lightroom Classic** (deferred to the project owner; note in report)

**Primary risk to verify first:** that the created Smart Collections actually populate. If a collection is empty despite photos being tagged, the smart-collection criteria strings in `smartcoll_rules.lua` (`"location"`, `"city"`, `operation = "=="`, `combine = "intersect"`) need correcting to the exact strings Lightroom's SDK expects — that module is the only place to change.

1. Plug-in Manager → Reload Plug-in.
2. Select several geotagged photos in different neighborhoods → **Library → Plug-in Extras → Create Location Collections...** → dialog shows photo + unique-location counts.
3. Run → progress bar advances ~1/sec per new location → summary reports tagged / skipped / unresolved / collections created.
4. Metadata panel: Sublocation, City, State, Country are filled on tagged photos.
5. Collections panel: a "Geo Locations" set exists with one Smart Collection per neighborhood; **each collection contains the expected photos** (the key check).
6. Add/geotag another photo in a known neighborhood, set its Sublocation+City (or re-run the command) → it appears in that smart collection automatically (auto-update).
7. Re-run the whole command → no duplicate collections; second run is fast (cache hit, no ~1/sec throttle).
8. Run with no selection → "select photos first"; run on photos with no GPS → "none have GPS".
9. v1/v2 commands still work (shared `plugin_paths` refactor didn't break them).

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/plugin_paths.lua PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua PhoneGeotagger.lrplugin/Info.lua
git commit -m "feat: Create Location Collections command with reverse geocoding"
```

---

### Task 7: README update for location collections

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add an "Organizing photos into location collections" section**

Insert this section into `README.md` immediately after the "Correcting a wrong geotag" section:

```markdown
## Organizing photos into location collections

Turn GPS coordinates into browsable, auto-updating Smart Collections named for
real places.

1. Select geotagged photos and run **Library → Plug-in Extras → Create
   Location Collections...**.
2. The plugin reverse-geocodes each location via OpenStreetMap, writes the
   Country / State / City / Sublocation IPTC fields, and creates a **Geo
   Locations** collection set with one Smart Collection per neighborhood.

Because the collections are Smart Collections keyed on the place-name fields,
they update themselves as you geocode more photos. Locations are cached
locally, so repeat runs and photos that share a spot cost no extra lookups.

**Note on the geocoder:** the default endpoint is the public OpenStreetMap
Nominatim service, which asks for at most one request per second — the plugin
throttles accordingly. For large libraries you can point the **Geocoder
endpoint** field at your own Nominatim instance.
```

Also add a line to the "Credits" section:

```markdown
- Reverse geocoding by [OpenStreetMap Nominatim](https://nominatim.org/).
```

- [ ] **Step 2: Final full-suite run**

Run: `busted`
Expected: all pass (92), `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document the location collections command"
```
