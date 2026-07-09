# Geotag Snapping + Streaming Location Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snap geotag coordinates so co-located photos share one pin, and convert Location Collections to a streaming, low-memory command that builds regular collections named by place hierarchy.

**Architecture:** Two small Lightroom-independent core modules (`coord_round`, `collection_name`) added with busted tests; `place_extract` adjusted; the Geotag dialog/pipeline apply rounding; the Location Collections command is rewritten to iterate photos and add them to regular collections in bounded flushes; `smartcoll_rules` is removed.

**Tech Stack:** Lua 5.1 (Lightroom runtime), Lightroom Classic SDK, OpenStreetMap Nominatim, busted.

**Spec:** `docs/superpowers/specs/2026-07-09-geotag-snap-and-streaming-collections-design.md`

## Global Constraints

- **Lua 5.1 compatibility everywhere** (no `goto`, no `table.unpack`, no `//`).
- **Flat file layout** inside `PhoneGeotagger.lrplugin/`; core modules never call Lightroom's `import`.
- Baseline suite is **87 passing**. Net after this work ≈ **95** (+coord_round, +collection_name, −smartcoll_rules; place_extract test count unchanged).
- Snapping default precision **4 decimals (~11 m)**; popup values `Exact → 8`, `~11 m → 4`, `~110 m → 3`.
- Collection naming: finest present level of `{sublocation, city, state, country}`, comma-joined with the next coarser present level; nil when none present.
- Streaming flush size: **500** photos (fixed internal constant `FLUSH_SIZE`).
- Nominatim: User-Agent `PhoneGeotagger/0.1 (github.com/mssadik73/phone-geotagger)`; throttle `LrTasks.sleep(1.1)` only after a real network lookup; failed lookups are not cached.
- Run tests with `busted` from the repo root. Commit after every passing task. Work on branch `feature/snap-and-streaming-collections`.

---

### Task 1: coord_round module

**Files:**
- Create: `PhoneGeotagger.lrplugin/coord_round.lua`
- Test: `spec/coord_round_spec.lua`

**Interfaces:**
- Produces: `coord_round.round(lat, lon, decimals)` → rounded `lat, lon` (two numbers), each `math.floor(x * 10^decimals + 0.5) / 10^decimals`.

- [ ] **Step 1: Write the failing tests**

`spec/coord_round_spec.lua`:

```lua
local coord_round = require "coord_round"

describe("coord_round.round", function()
  it("rounds to 4 decimals", function()
    local lat, lon = coord_round.round(23.780573, 90.279240, 4)
    assert.near(23.7806, lat, 1e-9)
    assert.near(90.2792, lon, 1e-9)
  end)

  it("collapses nearby coordinates to the same value", function()
    local a = coord_round.round(34.052210, -118.0, 4)
    local b = coord_round.round(34.052240, -118.0, 4)
    assert.equals(a, b) -- both 34.0522
  end)

  it("handles negative coordinates", function()
    local lat, lon = coord_round.round(-33.868800, 151.209255, 4)
    assert.near(-33.8688, lat, 1e-9)
    assert.near(151.2093, lon, 1e-9)
  end)

  it("rounds to 3 decimals (~110 m)", function()
    local lat = coord_round.round(34.052235, 0, 3)
    assert.near(34.052, lat, 1e-9)
  end)

  it("treats 8 decimals as effectively exact", function()
    local lat, lon = coord_round.round(34.05223456, -118.24368912, 8)
    assert.near(34.05223456, lat, 1e-9)
    assert.near(-118.24368912, lon, 1e-9)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/coord_round_spec.lua`
Expected: FAIL — `module 'coord_round' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/coord_round.lua`:

```lua
-- Rounds coordinates to a fixed decimal precision so co-located photos share
-- an identical value (one map pin) instead of scattering from interpolation.

local coord_round = {}

-- Returns lat, lon each rounded to `decimals` places.
function coord_round.round(lat, lon, decimals)
  local m = 10 ^ decimals
  return math.floor(lat * m + 0.5) / m, math.floor(lon * m + 0.5) / m
end

return coord_round
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/coord_round_spec.lua`
Expected: `5 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/coord_round.lua spec/coord_round_spec.lua
git commit -m "feat: coord_round to snap co-located photos to one coordinate"
```

---

### Task 2: Location-precision dropdown + apply rounding in the geotag pipeline

**Files:**
- Modify: `PhoneGeotagger.lrplugin/GeotagDialog.lua`
- Modify: `PhoneGeotagger.lrplugin/GeotagMenuItem.lua`

**Interfaces:**
- Consumes: `coord_round.round` (Task 1).
- Produces: `GeotagDialog.run` settings gains `precision = <decimals>` (integer). Manual verification in Lightroom; `luac -p` + full suite for no regressions.

- [ ] **Step 1: Add the precision pref default in GeotagDialog.lua**

Read `PhoneGeotagger.lrplugin/GeotagDialog.lua`. Find the block that seeds
props from prefs (it currently sets `props.mode`, `props.home_offset`,
`props.dest_offset`, `props.drift`, `props.max_gap_min`, `props.overwrite`,
`props.coverage`). Add one line among them:

```lua
    props.precision = prefs.precision or 4
```

- [ ] **Step 2: Add the precision popup to the Matching group box**

In the same file, find the `f:group_box { title = "Matching", ... }`. It
contains the "Maximum time gap" row and the "Overwrite existing GPS
coordinates" checkbox. Add this row inside that group box (after the max-gap
row is fine):

```lua
        f:row {
          f:static_text { title = "Location precision:" },
          f:popup_menu {
            value = bind "precision",
            items = {
              { title = "Exact", value = 8 },
              { title = "~11 m (4 decimals)", value = 4 },
              { title = "~110 m (3 decimals)", value = 3 },
            },
          },
        },
```

- [ ] **Step 3: Persist the pref and return it**

Still in `GeotagDialog.lua`, find where prefs are written on OK (the block with
`prefs.mode = props.mode` … `prefs.overwrite = ...`) and add:

```lua
    prefs.precision = props.precision
```

Then find the returned `result = { ... }` table (it has `points`,
`override_offset`, `home_offset`, `drift`, `max_gap_sec`, `overwrite`) and add:

```lua
      precision = props.precision,
```

- [ ] **Step 4: Apply rounding in GeotagMenuItem.lua**

Read `PhoneGeotagger.lrplugin/GeotagMenuItem.lua`. Add the require near the
other `require` lines:

```lua
local coord_round = require "coord_round"
```

Find the matcher call in the per-photo loop, which looks like:

```lua
          local lat, lon = matcher.match(settings.points, utc, settings.max_gap_sec)
          if lat then
            writes[#writes + 1] = { photo = photo, lat = lat, lon = lon }
```

Insert the rounding right after `if lat then`, so the snapped coordinate is
what gets written:

```lua
          local lat, lon = matcher.match(settings.points, utc, settings.max_gap_sec)
          if lat then
            lat, lon = coord_round.round(lat, lon, settings.precision)
            writes[#writes + 1] = { photo = photo, lat = lat, lon = lon }
```

- [ ] **Step 5: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/GeotagDialog.lua PhoneGeotagger.lrplugin/GeotagMenuItem.lua
busted
```
Expected: `luac` clean; `busted` still green (92 after Task 1).

- [ ] **Step 6: Manual test in Lightroom** (deferred to owner; note in report)

Geotag a burst of photos taken at one spot with precision "~11 m" → they land
on a single pin in the Map module. Switch to "Exact" and re-geotag (overwrite)
→ they scatter again. "~110 m" clusters more aggressively.

- [ ] **Step 7: Commit**

```bash
git add PhoneGeotagger.lrplugin/GeotagDialog.lua PhoneGeotagger.lrplugin/GeotagMenuItem.lua
git commit -m "feat: Location precision dropdown snaps geotags to one pin"
```

---

### Task 3: place_extract returns the raw neighborhood

**Files:**
- Modify: `PhoneGeotagger.lrplugin/place_extract.lua`
- Modify: `spec/place_extract_spec.lua`

**Interfaces:**
- Produces: `place_extract.extract(address)` → `{ country, state, city, sublocation }` where `sublocation` is the **raw neighborhood** (neighbourhood → suburb → quarter → city_district) or `nil` when there is none (no city fallback). `city`/`state`/`country` unchanged.

- [ ] **Step 1: Update the failing test**

In `spec/place_extract_spec.lua`, replace the test titled
`"falls back to city/town/village for both city and sublocation"` (the one
passing `{ village = "Lone Pine", state = "California" }` and asserting
`p.sublocation == "Lone Pine"`) with:

```lua
  it("returns nil sublocation when there is no neighbourhood", function()
    local p = place_extract.extract({ village = "Lone Pine", state = "California" })
    assert.equals("Lone Pine", p.city)
    assert.is_nil(p.sublocation)
  end)
```

Leave every other test unchanged.

- [ ] **Step 2: Run the test to verify it fails**

Run: `busted spec/place_extract_spec.lua`
Expected: FAIL — the current code returns `p.sublocation == "Lone Pine"` (city
fallback), so `assert.is_nil(p.sublocation)` fails.

- [ ] **Step 3: Remove the city fallback**

In `PhoneGeotagger.lrplugin/place_extract.lua`, change the sublocation line
from:

```lua
  local sub = first(address, { "neighbourhood", "suburb", "quarter", "city_district" })
    or city
```

to:

```lua
  local sub = first(address, { "neighbourhood", "suburb", "quarter", "city_district" })
```

(Leave the rest of the function unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/place_extract_spec.lua`
Expected: all pass (8).

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/place_extract.lua spec/place_extract_spec.lua
git commit -m "refactor: place_extract sublocation is the raw neighborhood (no city fallback)"
```

---

### Task 4: collection_name module

**Files:**
- Create: `PhoneGeotagger.lrplugin/collection_name.lua`
- Test: `spec/collection_name_spec.lua`

**Interfaces:**
- Consumes: a place table `{ sublocation, city, state, country }` (from `place_extract`).
- Produces: `collection_name.of(place)` → the collection name string (finest present level, plus the next coarser present level as context, comma-joined), or `nil` when no level is present. Empty-string fields count as absent.

- [ ] **Step 1: Write the failing tests**

`spec/collection_name_spec.lua`:

```lua
local collection_name = require "collection_name"

describe("collection_name.of", function()
  it("pairs neighborhood with city", function()
    assert.equals("Venice Beach, Los Angeles", collection_name.of({
      sublocation = "Venice Beach", city = "Los Angeles",
      state = "California", country = "United States" }))
  end)

  it("pairs neighborhood with state when city is absent", function()
    assert.equals("Venice Beach, California", collection_name.of({
      sublocation = "Venice Beach", state = "California" }))
  end)

  it("pairs city with state", function()
    assert.equals("Los Angeles, California", collection_name.of({
      city = "Los Angeles", state = "California", country = "United States" }))
  end)

  it("pairs city with country when state is absent", function()
    assert.equals("Los Angeles, United States", collection_name.of({
      city = "Los Angeles", country = "United States" }))
  end)

  it("pairs state with country", function()
    assert.equals("California, United States", collection_name.of({
      state = "California", country = "United States" }))
  end)

  it("uses country alone when it is the only level", function()
    assert.equals("United States", collection_name.of({ country = "United States" }))
  end)

  it("returns nil when no level is present", function()
    assert.is_nil(collection_name.of({}))
  end)

  it("treats empty-string fields as absent", function()
    assert.equals("Paris, France", collection_name.of({
      sublocation = "", city = "Paris", state = "", country = "France" }))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/collection_name_spec.lua`
Expected: FAIL — `module 'collection_name' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/collection_name.lua`:

```lua
-- Builds a regular-collection name from a reverse-geocoded place: the finest
-- present level, plus the next coarser present level for context/disambiguation.

local collection_name = {}

-- place: { sublocation, city, state, country }. Returns a name string or nil.
function collection_name.of(place)
  local levels = { place.sublocation, place.city, place.state, place.country }
  local primary_i
  for i = 1, #levels do
    local v = levels[i]
    if v ~= nil and v ~= "" then primary_i = i; break end
  end
  if not primary_i then return nil end
  local primary = levels[primary_i]
  for i = primary_i + 1, #levels do
    local v = levels[i]
    if v ~= nil and v ~= "" then
      return primary .. ", " .. v
    end
  end
  return primary
end

return collection_name
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/collection_name_spec.lua`
Expected: `8 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/collection_name.lua spec/collection_name_spec.lua
git commit -m "feat: collection_name builds hierarchical place collection names"
```

---

### Task 5: Simplify LocationDialog (drop overwrite, simplify the count line)

**Files:**
- Modify: `PhoneGeotagger.lrplugin/LocationDialog.lua`

**Interfaces:**
- Produces: `LocationDialog.run(args)` with `args = { photo_count, prefs }` → `{ set_name, endpoint }` or nil on cancel. No `overwrite`; no `unique_count`. Persists `loc_set_name`, `loc_endpoint`. Manual verification; `luac -p` + full suite.

- [ ] **Step 1: Rewrite LocationDialog.lua**

Replace the entire contents of `PhoneGeotagger.lrplugin/LocationDialog.lua`
with:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local LocationDialog = {}

-- args: { photo_count, prefs }
-- Returns { set_name, endpoint } or nil on cancel.
function LocationDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("LocationDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.set_name = (prefs.loc_set_name and prefs.loc_set_name ~= "" and prefs.loc_set_name)
      or "Geo Locations"
    props.endpoint = (prefs.loc_endpoint and prefs.loc_endpoint ~= "" and prefs.loc_endpoint)
      or "https://nominatim.openstreetmap.org/reverse"

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format(
          "%d photo(s) selected. Locations are looked up as needed "
          .. "(about one per second for new ones).", args.photo_count),
      },
      f:row {
        f:static_text { title = "Collection set name:" },
        f:edit_field { value = bind "set_name", width_in_chars = 24 },
      },
      f:row {
        f:static_text { title = "Geocoder endpoint:" },
        f:edit_field { value = bind "endpoint", fill_horizontal = 1 },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Create Location Collections",
      contents = contents,
      actionVerb = "Create Collections",
    }
    if action ~= "ok" then return end

    if props.set_name == nil or props.set_name == "" then props.set_name = "Geo Locations" end
    if props.endpoint == nil or props.endpoint == "" then
      props.endpoint = "https://nominatim.openstreetmap.org/reverse"
    end

    prefs.loc_set_name = props.set_name
    prefs.loc_endpoint = props.endpoint

    result = { set_name = props.set_name, endpoint = props.endpoint }
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
Expected: `luac` clean; `busted` still green (100 after Task 4).

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationDialog.lua
git commit -m "refactor: LocationDialog drops overwrite; simpler count line"
```

---

### Task 6: Rewrite LocationCollectionsMenuItem as a streaming regular-collections builder

**Files:**
- Modify (replace entirely): `PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`

**Interfaces:**
- Consumes: `geocode_client.reverse(http_get, endpoint, lat, lon)`, `place_extract.extract` (Task 3), `geo_cache.*`, `collection_name.of` (Task 4), `plugin_paths.geocode_cache_path`, `LocationDialog.run{photo_count, prefs}` (Task 5); Lightroom SDK (`getTargetPhoto`, `getTargetPhotos`, `getRawMetadata("gps")`, `withWriteAccessDo`, `createCollectionSet`, `createCollection`, `collection:addPhotos`, `LrHttp.get`, `LrProgressScope`, `LrTasks.sleep`, `LrTasks.pcall`).
- Produces: the streaming command. Manual verification; `luac -p` + full suite.

- [ ] **Step 1: Replace the file**

`PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua` (entire file):

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
local collection_name = require "collection_name"
local plugin_paths = require "plugin_paths"
local LocationDialog = require "LocationDialog"

local USER_AGENT = "PhoneGeotagger/0.1 (github.com/mssadik73/phone-geotagger)"
local FLUSH_SIZE = 500

local function http_get(url)
  local body = LrHttp.get(url, { { field = "User-Agent", value = USER_AGENT } })
  return body
end

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

    local cache_path = plugin_paths.geocode_cache_path()
    local cache = geo_cache.load(cache_path)

    -- Ensure the parent collection set exists.
    local set
    catalog:withWriteAccessDo("Location collections set", function()
      set = catalog:createCollectionSet(settings.set_name, nil, true)
    end)

    local colls = {}   -- name -> LrCollection (created lazily, reused across flushes)
    local pending = {} -- name -> { photo, ... } buffered for the next flush
    local pending_n = 0
    local added, unresolved, no_gps = 0, 0, 0

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
      geo_cache.save(cache_path, cache)
    end

    progress = LrProgressScope { title = "Building location collections" }
    progress:setCancelable(true)

    for i, photo in ipairs(photos) do
      if progress:isCanceled() then break end
      local g = photo:getRawMetadata("gps")
      if not (g and g.latitude and g.longitude) then
        no_gps = no_gps + 1
      else
        local place = geo_cache.get(cache, g.latitude, g.longitude)
        if not place then
          local addr = geocode_client.reverse(http_get, settings.endpoint,
            g.latitude, g.longitude)
          if addr then
            place = place_extract.extract(addr)
            geo_cache.put(cache, g.latitude, g.longitude, place)
          else
            place = {}
          end
          LrTasks.sleep(1.1) -- Nominatim: <= 1 req/sec, only on a real lookup
        end
        local name = collection_name.of(place)
        if name then
          pending[name] = pending[name] or {}
          pending[name][#pending[name] + 1] = photo
          pending_n = pending_n + 1
          added = added + 1
          if pending_n >= FLUSH_SIZE then flush() end
        else
          unresolved = unresolved + 1
        end
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
        .. "%d unresolved, %d without GPS.",
        added, n_colls, settings.set_name, unresolved, no_gps), "info")
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
Expected: `luac` clean; `busted` still green (100).

- [ ] **Step 3: Manual test in Lightroom** (deferred to owner; note in report)

1. Reload the plugin. Select geotagged photos across ≥2 neighborhoods → **Create
   Location Collections...** → dialog shows set name + endpoint (no overwrite).
2. Run → progress advances; a "Geo Locations" set fills with regular
   collections named "Neighborhood, City" (or the coarser fallback), each
   holding its photos.
3. Large selection (hundreds+) → memory stays flat; collections appear
   incrementally as flushes happen.
4. Re-run on overlapping photos → no duplicate membership; second run fast
   (cache hits, no ~1 s throttle).
5. Cancel mid-run → partial collections are consistent and the cache is saved.
6. A photo with no GPS is counted "without GPS"; empty selection → "select
   photos first".

- [ ] **Step 4: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua
git commit -m "feat: streaming regular Location Collections (iterate, name, add)"
```

---

### Task 7: Remove the now-unused smartcoll_rules module

**Files:**
- Delete: `PhoneGeotagger.lrplugin/smartcoll_rules.lua`
- Delete: `spec/smartcoll_rules_spec.lua`

**Interfaces:**
- Nothing consumes `smartcoll_rules` after Task 6 (verify before deleting).

- [ ] **Step 1: Confirm no references remain**

Run:
```bash
grep -rn "smartcoll_rules" PhoneGeotagger.lrplugin spec
```
Expected: only `PhoneGeotagger.lrplugin/smartcoll_rules.lua` and
`spec/smartcoll_rules_spec.lua` themselves — no `require "smartcoll_rules"` in
any other file. (If any other file references it, STOP — Task 6 was
incomplete.)

- [ ] **Step 2: Delete the module and its spec**

```bash
git rm PhoneGeotagger.lrplugin/smartcoll_rules.lua spec/smartcoll_rules_spec.lua
```

- [ ] **Step 3: Run the full suite**

Run: `busted`
Expected: all pass, ~95 (100 − 5 removed smartcoll_rules tests).

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: remove unused smartcoll_rules (collections are now regular)"
```

---

### Task 8: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the "Organizing photos into location collections" section**

Replace the existing "Organizing photos into location collections" section
body (keep the `## Organizing photos into location collections` heading) with:

```markdown
Turn GPS coordinates into browsable collections named for real places.

1. Select geotagged photos and run **Library → Plug-in Extras → Create
   Location Collections...**.
2. The plugin reverse-geocodes each photo via OpenStreetMap and adds it to a
   collection named for its place — `Neighborhood, City` where a neighborhood
   is known, otherwise `City, State` or `State, Country`. All the collections
   live in a **Geo Locations** collection set.

These are regular collections (a snapshot of the photos you ran it on), so
re-run the command after geotagging more photos to fold them in — photos
already in a collection are left as-is. Locations are cached locally, so
repeat runs and photos that share a spot cost no extra lookups, and very large
selections are processed in bounded batches to keep memory flat.

**Note on the geocoder:** the default endpoint is the public OpenStreetMap
Nominatim service, which asks for at most one request per second — the plugin
throttles accordingly. For large libraries you can point the **Geocoder
endpoint** field at your own Nominatim instance.
```

- [ ] **Step 2: Final full-suite run**

Run: `busted`
Expected: all pass (~95), `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe regular, re-runnable location collections"
```
