# Geotag Snapping + Streaming Location Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snap geotag coordinates so co-located photos share one pin, and convert Location Collections to a streaming, low-memory command that builds regular collections named by place hierarchy.

**Architecture:** Two small Lightroom-independent core modules (`coord_round`, `collection_name`) added with busted tests; `place_extract` adjusted; the Geotag dialog/pipeline apply rounding; the Location Collections command is rewritten to iterate photos and add them to regular collections in bounded flushes; `smartcoll_rules` is removed.

**Tech Stack:** Lua 5.1 (Lightroom runtime), Lightroom Classic SDK, OpenStreetMap Nominatim, busted.

**Spec:** `docs/superpowers/specs/2026-07-09-geotag-snap-and-streaming-collections-design.md`

## Global Constraints

- **Lua 5.1 compatibility everywhere** (no `goto`, no `table.unpack`, no `//`).
- **Flat file layout** inside `PhoneGeotagger.lrplugin/`; core modules never call Lightroom's `import`.
- Baseline suite is **87 passing**. Net after this work ≈ **101** (+5 coord_round, +14 collection_name, −5 smartcoll_rules; place_extract test count unchanged).
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
- Consumes: a place table `{ sublocation, city, state, country }` (from `place_extract`); a format `{ primary = <level>, secondary = <level> | "none" }` where level ∈ `"sublocation" | "city" | "state" | "country"`.
- Produces:
  - `collection_name.auto(place)` → finest present level + next coarser present level, comma-joined; `nil` when no level present.
  - `collection_name.of(place, fmt)` → chosen-format name: `place[fmt.primary]`, appending `", " .. place[fmt.secondary]` when the secondary is set (not `"none"`), differs from the primary level, and is present; falls back to `auto(place)` when `place[fmt.primary]` is absent; `nil` when nothing present.
  - `collection_name.format_error(primary, secondary)` → `nil` if valid, else an error string. Valid when `secondary == "none"` or `rank(secondary) > rank(primary)`, `rank = { sublocation=1, city=2, state=3, country=4 }`; also rejects an unknown primary/secondary.
- Empty-string fields count as absent throughout.

- [ ] **Step 1: Write the failing tests**

`spec/collection_name_spec.lua`:

```lua
local collection_name = require "collection_name"

describe("collection_name.auto", function()
  it("pairs neighborhood with city", function()
    assert.equals("Venice Beach, Los Angeles", collection_name.auto({
      sublocation = "Venice Beach", city = "Los Angeles",
      state = "California", country = "United States" }))
  end)

  it("pairs city with state when there is no neighborhood", function()
    assert.equals("Los Angeles, California", collection_name.auto({
      city = "Los Angeles", state = "California", country = "United States" }))
  end)

  it("uses country alone when it is the only level", function()
    assert.equals("United States", collection_name.auto({ country = "United States" }))
  end)

  it("returns nil when no level is present", function()
    assert.is_nil(collection_name.auto({}))
  end)

  it("treats empty-string fields as absent", function()
    assert.equals("Paris, France", collection_name.auto({
      sublocation = "", city = "Paris", state = "", country = "France" }))
  end)
end)

describe("collection_name.of", function()
  local place = {
    sublocation = "Venice Beach", city = "Los Angeles",
    state = "California", country = "United States",
  }

  it("applies primary + secondary", function()
    assert.equals("Los Angeles, California",
      collection_name.of(place, { primary = "city", secondary = "state" }))
  end)

  it("omits the secondary when it is none", function()
    assert.equals("Los Angeles",
      collection_name.of(place, { primary = "city", secondary = "none" }))
  end)

  it("omits the secondary when it equals the primary", function()
    assert.equals("Los Angeles",
      collection_name.of(place, { primary = "city", secondary = "city" }))
  end)

  it("falls back to auto when the primary level is absent", function()
    local p = { city = "Los Angeles", state = "California" }
    assert.equals("Los Angeles, California",
      collection_name.of(p, { primary = "sublocation", secondary = "city" }))
  end)

  it("omits the secondary when it is absent for this photo", function()
    local p = { city = "Los Angeles" }
    assert.equals("Los Angeles",
      collection_name.of(p, { primary = "city", secondary = "state" }))
  end)
end)

describe("collection_name.format_error", function()
  it("accepts a broader secondary", function()
    assert.is_nil(collection_name.format_error("sublocation", "city"))
    assert.is_nil(collection_name.format_error("city", "country"))
  end)

  it("accepts a none secondary", function()
    assert.is_nil(collection_name.format_error("country", "none"))
  end)

  it("rejects a secondary that is not broader than the primary", function()
    assert.is_string(collection_name.format_error("city", "sublocation"))
    assert.is_string(collection_name.format_error("city", "city"))
  end)

  it("rejects an unknown level", function()
    assert.is_string(collection_name.format_error("borough", "city"))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/collection_name_spec.lua`
Expected: FAIL — `module 'collection_name' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/collection_name.lua`:

```lua
-- Builds a regular-collection name from a reverse-geocoded place, either from
-- an explicit primary+secondary format or automatically (finest present level
-- plus the next coarser present level). Also validates a chosen format.

local collection_name = {}

local ORDER = { "sublocation", "city", "state", "country" } -- fine -> coarse
local RANK = { sublocation = 1, city = 2, state = 3, country = 4 }

local function present(v)
  return v ~= nil and v ~= ""
end

-- Finest present level + next coarser present level, comma-joined; nil if none.
function collection_name.auto(place)
  local primary_i
  for i = 1, #ORDER do
    if present(place[ORDER[i]]) then primary_i = i; break end
  end
  if not primary_i then return nil end
  local primary = place[ORDER[primary_i]]
  for i = primary_i + 1, #ORDER do
    if present(place[ORDER[i]]) then
      return primary .. ", " .. place[ORDER[i]]
    end
  end
  return primary
end

-- Applies fmt = { primary, secondary }; falls back to auto when the primary
-- level is absent for this place.
function collection_name.of(place, fmt)
  if not fmt then return collection_name.auto(place) end
  local primary = place[fmt.primary]
  if not present(primary) then return collection_name.auto(place) end
  local sec = fmt.secondary
  if sec and sec ~= "none" and sec ~= fmt.primary and present(place[sec]) then
    return primary .. ", " .. place[sec]
  end
  return primary
end

-- nil if the format is valid, else an error message.
function collection_name.format_error(primary, secondary)
  if not RANK[primary] then
    return "Unknown primary level: " .. tostring(primary)
  end
  if secondary == nil or secondary == "none" then
    return nil
  end
  if not RANK[secondary] then
    return "Unknown secondary level: " .. tostring(secondary)
  end
  if RANK[secondary] <= RANK[primary] then
    return "The secondary level must be broader than the primary level, "
      .. "or set to (none)."
  end
  return nil
end

return collection_name
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/collection_name_spec.lua`
Expected: `14 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/collection_name.lua spec/collection_name_spec.lua
git commit -m "feat: collection_name with format, auto fallback, and validation"
```

---

### Task 5: LocationDialog — drop overwrite, add the format chooser + validation

**Files:**
- Modify: `PhoneGeotagger.lrplugin/LocationDialog.lua`

**Interfaces:**
- Consumes: `collection_name.format_error` (Task 4).
- Produces: `LocationDialog.run(args)` with `args = { photo_count, prefs }` → `{ set_name, endpoint, primary, secondary }` or nil on cancel. No `overwrite`. Persists `loc_set_name`, `loc_endpoint`, `loc_primary`, `loc_secondary`. Defaults: primary `"sublocation"` (most granular), secondary `"city"`. Re-presents the dialog with an error message if the chosen format is invalid; only returns a valid format. Manual verification; `luac -p` + full suite.

- [ ] **Step 1: Rewrite LocationDialog.lua**

Replace the entire contents of `PhoneGeotagger.lrplugin/LocationDialog.lua`
with:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local collection_name = require "collection_name"

local LocationDialog = {}

local LEVEL_ITEMS = {
  { title = "Neighborhood", value = "sublocation" },
  { title = "City", value = "city" },
  { title = "State / Province", value = "state" },
  { title = "Country", value = "country" },
}
local SECONDARY_ITEMS = {
  { title = "(none)", value = "none" },
  { title = "Neighborhood", value = "sublocation" },
  { title = "City", value = "city" },
  { title = "State / Province", value = "state" },
  { title = "Country", value = "country" },
}

-- args: { photo_count, prefs }
-- Returns { set_name, endpoint, primary, secondary } or nil on cancel.
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
    props.primary = prefs.loc_primary or "sublocation"
    props.secondary = prefs.loc_secondary or "city"

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
      if action ~= "ok" then return end -- cancel: result stays nil

      if props.set_name == nil or props.set_name == "" then props.set_name = "Geo Locations" end
      if props.endpoint == nil or props.endpoint == "" then
        props.endpoint = "https://nominatim.openstreetmap.org/reverse"
      end

      local ferr = collection_name.format_error(props.primary, props.secondary)
      if ferr then
        LrDialogs.message("Invalid collection name format", ferr, "warning")
      else
        prefs.loc_set_name = props.set_name
        prefs.loc_endpoint = props.endpoint
        prefs.loc_primary = props.primary
        prefs.loc_secondary = props.secondary
        result = {
          set_name = props.set_name, endpoint = props.endpoint,
          primary = props.primary, secondary = props.secondary,
        }
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
Expected: `luac` clean; `busted` still green (106 after Task 4).

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationDialog.lua
git commit -m "feat: LocationDialog format chooser (primary/secondary) with validation"
```

---

### Task 6: Rewrite LocationCollectionsMenuItem as a streaming regular-collections builder

**Files:**
- Modify (replace entirely): `PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`

**Interfaces:**
- Consumes: `geocode_client.reverse(http_get, endpoint, lat, lon)`, `place_extract.extract` (Task 3), `geo_cache.*`, `collection_name.of(place, fmt)` (Task 4), `plugin_paths.geocode_cache_path`, `LocationDialog.run{photo_count, prefs}` → `{set_name, endpoint, primary, secondary}` (Task 5); Lightroom SDK (`getTargetPhoto`, `getTargetPhotos`, `getRawMetadata("gps")`, `withWriteAccessDo`, `createCollectionSet`, `createCollection`, `collection:addPhotos`, `LrHttp.get`, `LrProgressScope`, `LrTasks.sleep`, `LrTasks.pcall`). Builds `fmt = { primary = settings.primary, secondary = settings.secondary }` and passes it to `collection_name.of`.
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
    local fmt = { primary = settings.primary, secondary = settings.secondary }

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
Expected: `luac` clean; `busted` still green (106).

- [ ] **Step 3: Manual test in Lightroom** (deferred to owner; note in report)

1. Reload the plugin. Select geotagged photos across ≥2 neighborhoods → **Create
   Location Collections...** → dialog shows set name + endpoint + the Primary /
   Secondary format popups (default Neighborhood / City, no overwrite).
2. Run → progress advances; a "Geo Locations" set fills with regular
   collections named per the chosen format ("Neighborhood, City" by default,
   with the auto fallback for photos missing the primary level), each holding
   its photos. Change the format (e.g. City / State) and re-run to confirm the
   names follow it; pick an invalid combo (e.g. City / Neighborhood) → the
   dialog shows an error and stays open.
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
Expected: all pass, 101 (106 − 5 removed smartcoll_rules tests).

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
2. Choose the **collection name format** — a primary level (Neighborhood /
   City / State / Country) and an optional secondary level for context. The
   default is `Neighborhood, City`. The plugin reverse-geocodes each photo via
   OpenStreetMap and adds it to a collection named by that format (e.g.
   `Venice Beach, Los Angeles`), falling back to the finest available level for
   photos that lack the chosen one. All the collections live in a **Geo
   Locations** collection set.

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
Expected: all pass (101), `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe regular, re-runnable location collections"
```
