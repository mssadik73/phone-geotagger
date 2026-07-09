# Google POI Location Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Name location collections by real points of interest from Google Places, with City/State/Country from Google, dropping OpenStreetMap entirely and taking the API key from the Plug-in Manager config screen.

**Architecture:** One new core module `google_geo` (Places `searchNearby` for POI + address, Geocoding reverse as fallback) with busted tests; `collection_name` levels become POI/City/State/Country; a `PluginInfoProvider` adds the key field to the Plug-in Manager; the streaming Location Collections command is rewired to Google; the Nominatim client and parser are removed.

**Tech Stack:** Lua 5.1 (Lightroom runtime), Lightroom Classic SDK, Google Places API (New) + Google Geocoding API, vendored dkjson, busted.

**Spec:** `docs/superpowers/specs/2026-07-09-google-poi-collections-design.md`

## Global Constraints

- **Lua 5.1 compatible everywhere** (no `goto`, no `table.unpack`, no `//`).
- **Flat file layout** in `PhoneGeotagger.lrplugin/`; core modules never call Lightroom's `import` (they may `require "dkjson"`).
- Naming levels fine→coarse: `poi < city < state < country`. Format default primary=`poi`, secondary=`city`.
- Google Places `searchNearby`: `POST https://places.googleapis.com/v1/places:searchNearby`, headers `Content-Type: application/json`, `X-Goog-Api-Key: <key>`, `X-Goog-FieldMask: places.displayName,places.addressComponents`; body `includedTypes` (notable list, one constant), `maxResultCount: 1`, `rankPreference: "DISTANCE"`, `locationRestriction.circle = { center:{latitude,longitude}, radius: 200 }`.
- Google Geocoding reverse: `GET https://maps.googleapis.com/maps/api/geocode/json?latlng=<lat>,<lon>&key=<key>`.
- Address components → `locality`/`postal_town` = city, `administrative_area_level_1` = state, `country` = country. (Places uses `longText`; Geocoding uses `long_name`.)
- API key lives in `prefs.google_api_key`, set in the Plug-in Manager; the command **requires** it.
- Cache file `geocode-v3.json`; place shape `{ poi, city, state, country }`.
- Run tests with `busted`. Commit after every passing task. Work on branch `feature/google-poi-collections`. Baseline suite **101**; net ≈ **94** (+google_geo, −geocode_client, −place_extract; collection_name count unchanged).

---

### Task 1: collection_name — POI levels

**Files:**
- Modify: `PhoneGeotagger.lrplugin/collection_name.lua`
- Modify: `spec/collection_name_spec.lua`

**Interfaces:**
- Produces (unchanged signatures, new level set): `collection_name.auto(place)`, `collection_name.of(place, fmt)`, `collection_name.format_error(primary, secondary)`. `place = { poi, city, state, country }`; levels `"poi" | "city" | "state" | "country"`; `RANK = { poi=1, city=2, state=3, country=4 }`.

- [ ] **Step 1: Update the tests to use `poi`**

In `spec/collection_name_spec.lua`, replace every `sublocation` with `poi`
(both the field name in place tables and the level string in `of`/`format_error`
calls). The eight representative replacements:

```lua
-- auto: "pairs neighborhood with city" test place:
    assert.equals("Venice Beach, Los Angeles", collection_name.auto({
      poi = "Venice Beach", city = "Los Angeles",
      state = "California", country = "United States" }))
-- auto: "treats empty-string fields as absent":
    assert.equals("Paris, France", collection_name.auto({
      poi = "", city = "Paris", state = "", country = "France" }))
-- of: shared place:
  local place = {
    poi = "Venice Beach", city = "Los Angeles",
    state = "California", country = "United States",
  }
-- of: "falls back to auto when the primary level is absent":
    local p = { city = "Los Angeles", state = "California" }
    assert.equals("Los Angeles, California",
      collection_name.of(p, { primary = "poi", secondary = "city" }))
-- format_error: accepts a broader secondary:
    assert.is_nil(collection_name.format_error("poi", "city"))
-- format_error: rejects not-broader:
    assert.is_string(collection_name.format_error("city", "poi"))
```

Apply the same `sublocation`→`poi` rename to every other occurrence in the file
(the "pairs neighborhood with state", "omits the secondary when it equals the
primary" using `primary="poi"`, etc.). Do not change test counts or assertions
otherwise.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `busted spec/collection_name_spec.lua`
Expected: FAIL — the module still uses `sublocation`, so `place.poi` reads nil
and the `poi` level isn't in `RANK`.

- [ ] **Step 3: Update collection_name.lua**

In `PhoneGeotagger.lrplugin/collection_name.lua`, change the two constants:

```lua
local ORDER = { "poi", "city", "state", "country" } -- fine -> coarse
local RANK = { poi = 1, city = 2, state = 3, country = 4 }
```

Leave `present`, `auto`, `of`, and `format_error` bodies unchanged (they read
`place[ORDER[i]]` / `place[fmt.primary]` and `RANK[...]`, which now use `poi`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/collection_name_spec.lua`
Expected: `14 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/collection_name.lua spec/collection_name_spec.lua
git commit -m "refactor: collection_name levels are poi/city/state/country"
```

---

### Task 2: google_geo module

**Files:**
- Create: `PhoneGeotagger.lrplugin/google_geo.lua`
- Test: `spec/google_geo_spec.lua`

**Interfaces:**
- Consumes: injected `http_post(url, body, headers) → body_string` and `http_get(url) → body_string`; `dkjson`.
- Produces:
  - `google_geo.nearest_poi(http_post, key, lat, lon, radius)` → `{ poi, city, state, country }` (any field may be nil; `{}` when no notable place) or `nil, error`.
  - `google_geo.reverse(http_get, key, lat, lon)` → `{ city, state, country }` (`{}` when no result) or `nil, error`.

- [ ] **Step 1: Write the failing tests**

`spec/google_geo_spec.lua`:

```lua
local google_geo = require "google_geo"

local PLACES_BODY = [[{
  "places": [
    {
      "displayName": { "text": "Griffith Observatory", "languageCode": "en" },
      "addressComponents": [
        { "longText": "Los Angeles", "types": ["locality", "political"] },
        { "longText": "California", "types": ["administrative_area_level_1"] },
        { "longText": "United States", "types": ["country", "political"] }
      ]
    }
  ]
}]]

local GEOCODE_BODY = [[{
  "results": [
    {
      "address_components": [
        { "long_name": "Lone Pine", "types": ["locality", "political"] },
        { "long_name": "California", "types": ["administrative_area_level_1"] },
        { "long_name": "United States", "types": ["country", "political"] }
      ]
    }
  ],
  "status": "OK"
}]]

local function fake_post(body)
  local calls = {}
  return function(url, reqbody, headers)
    calls[#calls + 1] = { url = url, body = reqbody, headers = headers }
    return body
  end, calls
end

local function fake_get(body)
  local calls = {}
  return function(url) calls[#calls + 1] = url; return body end, calls
end

describe("google_geo.nearest_poi", function()
  it("parses POI and address from a Places response", function()
    local post = fake_post(PLACES_BODY)
    local p = assert(google_geo.nearest_poi(post, "KEY", 34.1184, -118.3004, 200))
    assert.equals("Griffith Observatory", p.poi)
    assert.equals("Los Angeles", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
  end)

  it("sends the searchNearby URL, key header, and field mask", function()
    local post, calls = fake_post(PLACES_BODY)
    google_geo.nearest_poi(post, "KEY", 34.0, -118.0, 200)
    local c = calls[1]
    assert.equals("https://places.googleapis.com/v1/places:searchNearby", c.url)
    local hkey, hmask
    for _, h in ipairs(c.headers) do
      if h.field == "X-Goog-Api-Key" then hkey = h.value end
      if h.field == "X-Goog-FieldMask" then hmask = h.value end
    end
    assert.equals("KEY", hkey)
    assert.equals("places.displayName,places.addressComponents", hmask)
    assert.matches("searchNearby", c.url)
    assert.matches('"rankPreference":"DISTANCE"', (c.body:gsub("%s", "")))
    assert.matches('"radius":200', (c.body:gsub("%s", "")))
  end)

  it("returns an empty table when there is no notable place", function()
    local post = fake_post('{"places": []}')
    assert.same({}, google_geo.nearest_poi(post, "KEY", 0, 0, 200))
  end)

  it("errors on a Google error body", function()
    local post = fake_post('{"error": {"code": 403, "message": "denied"}}')
    local p, err = google_geo.nearest_poi(post, "KEY", 0, 0, 200)
    assert.is_nil(p)
    assert.matches("denied", err)
  end)

  it("errors on an empty response", function()
    local post = fake_post("")
    local p, err = google_geo.nearest_poi(post, "KEY", 0, 0, 200)
    assert.is_nil(p)
    assert.is_string(err)
  end)
end)

describe("google_geo.reverse", function()
  it("parses city/state/country from a Geocoding response", function()
    local get = fake_get(GEOCODE_BODY)
    local p = assert(google_geo.reverse(get, "KEY", 36.5, -116.9))
    assert.equals("Lone Pine", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
    assert.is_nil(p.poi)
  end)

  it("returns an empty table when there is no result", function()
    local get = fake_get('{"results": [], "status": "ZERO_RESULTS"}')
    assert.same({}, google_geo.reverse(get, "KEY", 0, 0))
  end)

  it("errors on a non-OK status", function()
    local get = fake_get('{"results": [], "status": "REQUEST_DENIED"}')
    local p, err = google_geo.reverse(get, "KEY", 0, 0)
    assert.is_nil(p)
    assert.matches("REQUEST_DENIED", err)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/google_geo_spec.lua`
Expected: FAIL — `module 'google_geo' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/google_geo.lua`:

```lua
-- Google geocoding: nearest notable POI (Places API New) plus a reverse
-- Geocoding fallback for city/state/country. HTTP is injected so this module
-- stays Lightroom-free and unit-testable.

local dkjson = require "dkjson"

local google_geo = {}

-- The single place to adjust if Google rejects a type. Notable place types.
local INCLUDED_TYPES = {
  "tourist_attraction", "park", "national_park", "museum", "art_gallery",
  "historical_landmark", "monument", "cultural_landmark", "church", "mosque",
  "synagogue", "hindu_temple", "amusement_park", "zoo", "aquarium", "stadium",
  "plaza", "garden",
}

-- Extract city/state/country from a Google address-components list.
-- name_key is "longText" (Places) or "long_name" (Geocoding).
local function address(components, name_key)
  local city, state, country
  for _, c in ipairs(components or {}) do
    local val = c[name_key]
    for _, t in ipairs(c.types or {}) do
      if (t == "locality" or t == "postal_town") and not city then city = val
      elseif t == "administrative_area_level_1" and not state then state = val
      elseif t == "country" and not country then country = val
      end
    end
  end
  return city, state, country
end

-- Returns { poi, city, state, country } (or {} when no notable place), or nil, err.
function google_geo.nearest_poi(http_post, key, lat, lon, radius)
  local body = dkjson.encode({
    includedTypes = INCLUDED_TYPES,
    maxResultCount = 1,
    rankPreference = "DISTANCE",
    locationRestriction = {
      circle = {
        center = { latitude = lat, longitude = lon },
        radius = radius,
      },
    },
  })
  local headers = {
    { field = "Content-Type", value = "application/json" },
    { field = "X-Goog-Api-Key", value = key },
    { field = "X-Goog-FieldMask", value = "places.displayName,places.addressComponents" },
  }
  local resp = http_post("https://places.googleapis.com/v1/places:searchNearby",
    body, headers)
  if not resp or resp == "" then return nil, "no response from Places" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Places response" end
  if doc.error then
    return nil, "Places error: " .. tostring(doc.error.message or doc.error)
  end
  local places = doc.places
  if type(places) ~= "table" or not places[1] then return {} end
  local p = places[1]
  local city, state, country = address(p.addressComponents, "longText")
  return {
    poi = p.displayName and p.displayName.text or nil,
    city = city, state = state, country = country,
  }
end

-- Returns { city, state, country } (or {} when no result), or nil, err.
function google_geo.reverse(http_get, key, lat, lon)
  local url = string.format(
    "https://maps.googleapis.com/maps/api/geocode/json?latlng=%.7f,%.7f&key=%s",
    lat, lon, key)
  local resp = http_get(url)
  if not resp or resp == "" then return nil, "no response from Geocoding" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Geocoding response" end
  if doc.status and doc.status ~= "OK" and doc.status ~= "ZERO_RESULTS" then
    return nil, "Geocoding status: " .. tostring(doc.status)
  end
  local results = doc.results
  if type(results) ~= "table" or not results[1] then return {} end
  local city, state, country = address(results[1].address_components, "long_name")
  return { city = city, state = state, country = country }
end

return google_geo
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/google_geo_spec.lua`
Expected: `8 successes / 0 failures`

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: all pass (109), `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/google_geo.lua spec/google_geo_spec.lua
git commit -m "feat: google_geo for nearest-POI and reverse geocoding"
```

---

### Task 3: Plug-in Manager config screen for the API key

**Files:**
- Create: `PhoneGeotagger.lrplugin/PluginInfoProvider.lua`
- Modify: `PhoneGeotagger.lrplugin/Info.lua`

**Interfaces:**
- Produces: a Plug-in Manager section binding an edit field to `prefs.google_api_key`. Manual verification; `luac -p` + full suite.

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
        title = "Used by \"Create Location Collections\" for POI names and "
          .. "reverse geocoding. Enable the Places API (New) and the Geocoding "
          .. "API on your Google Cloud project.",
        fill_horizontal = 1,
      },
    },
  }
end

return provider
```

- [ ] **Step 2: Register it in Info.lua**

In `PhoneGeotagger.lrplugin/Info.lua`, add this top-level key (next to
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
Expected: `luac` clean; `busted` still green (109).

- [ ] **Step 4: Manual test in Lightroom** (deferred to owner; note in report)

File → Plug-in Manager → select Phone Geotagger → a "Phone Geotagger" section
shows a "Google API key" field; typing a value and reopening the manager
persists it.

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/PluginInfoProvider.lua PhoneGeotagger.lrplugin/Info.lua
git commit -m "feat: Google API key field in the Plug-in Manager"
```

---

### Task 4: LocationDialog — drop endpoint, POI level popups

**Files:**
- Modify: `PhoneGeotagger.lrplugin/LocationDialog.lua`

**Interfaces:**
- Produces: `LocationDialog.run(args)` with `args = { photo_count, prefs }` → `{ set_name, primary, secondary }` or nil on cancel. No endpoint. Level popups list POI/City/State/Country; default primary `"poi"`, secondary `"city"`. Persists `loc_set_name`, `loc_primary`, `loc_secondary`. Manual verification; `luac -p` + full suite.

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

-- args: { photo_count, prefs } -> { set_name, primary, secondary } or nil.
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
        title = string.format(
          "%d photo(s) selected. Locations are looked up as needed.",
          args.photo_count),
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
        result = {
          set_name = props.set_name,
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
Expected: `luac` clean; `busted` still green (109).

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/LocationDialog.lua
git commit -m "refactor: LocationDialog POI levels, drop the endpoint field"
```

---

### Task 5: Rewire LocationCollectionsMenuItem to Google + v3 cache

**Files:**
- Modify: `PhoneGeotagger.lrplugin/plugin_paths.lua` (cache filename → v3)
- Modify (replace entirely): `PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua`

**Interfaces:**
- Consumes: `google_geo.nearest_poi` / `google_geo.reverse` (Task 2), `collection_name.of` (Task 1), `geo_cache.*`, `plugin_paths.geocode_cache_path`, `LocationDialog.run` (Task 4); Lightroom SDK (`LrHttp.post`, `LrHttp.get`, `getTargetPhoto(s)`, `getRawMetadata("gps")`, `withWriteAccessDo`, `createCollectionSet`, `createCollection`, `collection:addPhotos`, `LrProgressScope`, `LrTasks.pcall`, `LrPrefs`).
- Produces: the Google-backed streaming command. Manual verification; `luac -p` + full suite.

- [ ] **Step 1: Bump the cache filename in plugin_paths.lua**

In `PhoneGeotagger.lrplugin/plugin_paths.lua`, change the geocode cache filename
(the place shape changed to include `poi`):

```lua
  return LrPathUtils.child(data_dir(), "geocode-v3.json")
```

(Update the accompanying comment to say "-v3" and mention the POI shape. Leave
`cache_path()` — history.csv — untouched.)

- [ ] **Step 2: Replace LocationCollectionsMenuItem.lua**

`PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua` (entire file):

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local google_geo = require "google_geo"
local geo_cache = require "geo_cache"
local collection_name = require "collection_name"
local plugin_paths = require "plugin_paths"
local LocationDialog = require "LocationDialog"

local POI_RADIUS = 200
local FLUSH_SIZE = 500

local function http_post(url, body, headers)
  return (LrHttp.post(url, body, headers))
end
local function http_get(url)
  return (LrHttp.get(url))
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

    local prefs = LrPrefs.prefsForPlugin()
    local key = prefs.google_api_key
    if not key or key == "" then
      LrDialogs.message("Create Location Collections",
        "Set your Google API key in the Plug-in Manager "
        .. "(File > Plug-in Manager > Phone Geotagger) first.", "info")
      return
    end

    local photos = catalog:getTargetPhotos()
    local settings = LocationDialog.run { photo_count = #photos, prefs = prefs }
    if not settings then return end
    local fmt = { primary = settings.primary, secondary = settings.secondary }

    local cache_path = plugin_paths.geocode_cache_path()
    local cache = geo_cache.load(cache_path)

    local set
    catalog:withWriteAccessDo("Location collections set", function()
      set = catalog:createCollectionSet(settings.set_name, nil, true)
    end)

    local colls = {}
    local pending = {}
    local pending_n = 0
    local added, unresolved, no_gps = 0, 0, 0

    local function flush()
      if pending_n > 0 then
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
          place = google_geo.nearest_poi(http_post, key, g.latitude, g.longitude, POI_RADIUS) or {}
          local has_poi = place.poi and place.poi ~= ""
          local has_city = place.city and place.city ~= ""
          if not has_poi and not has_city then
            local rev = google_geo.reverse(http_get, key, g.latitude, g.longitude)
            if rev then
              place.city = place.city or rev.city
              place.state = place.state or rev.state
              place.country = place.country or rev.country
            end
          end
          if place.poi or place.city or place.state or place.country then
            geo_cache.put(cache, g.latitude, g.longitude, place)
          end
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

- [ ] **Step 3: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/plugin_paths.lua PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua
busted
```
Expected: `luac` clean; `busted` still green (109).

- [ ] **Step 4: Manual test in Lightroom** (deferred to owner; note in report)

1. Reload the plugin (remove + re-add, then relaunch so the new files register).
2. With no key set → run Create Location Collections → the "set your key" message.
3. Set the key in Plug-in Manager → run → collections named by POI
   ("Griffith Observatory, Los Angeles"), with City/State/Country fallback for
   photos with no nearby notable place. Confirm Google accepts the
   `includedTypes` (no error dialog); if a type is rejected, fix the constant in
   `google_geo.lua`.
4. `geocode-v3.json` appears next to `history.csv`; re-run is fast (cache hits);
   cancel mid-run is consistent.

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/plugin_paths.lua PhoneGeotagger.lrplugin/LocationCollectionsMenuItem.lua
git commit -m "feat: Google-backed Location Collections (POI + reverse), v3 cache"
```

---

### Task 6: Remove the OpenStreetMap client and parser

**Files:**
- Delete: `PhoneGeotagger.lrplugin/geocode_client.lua`, `spec/geocode_client_spec.lua`
- Delete: `PhoneGeotagger.lrplugin/place_extract.lua`, `spec/place_extract_spec.lua`

- [ ] **Step 1: Confirm no references remain**

Run:
```bash
grep -rn "geocode_client\|place_extract" PhoneGeotagger.lrplugin spec
```
Expected: only the four files being deleted reference their own names — no
`require "geocode_client"` or `require "place_extract"` anywhere else. (If any
other file still requires them, STOP — Task 5 was incomplete.)

- [ ] **Step 2: Delete the files**

```bash
git rm PhoneGeotagger.lrplugin/geocode_client.lua spec/geocode_client_spec.lua \
       PhoneGeotagger.lrplugin/place_extract.lua spec/place_extract_spec.lua
```

- [ ] **Step 3: Run the full suite**

Run: `busted`
Expected: all pass, ~95 (109 − 6 geocode_client − 8 place_extract).

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: remove OpenStreetMap client and parser (Google only now)"
```

---

### Task 7: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the "Organizing photos into location collections" section**

Replace the body of the existing `## Organizing photos into location collections`
section (keep the heading) with:

```markdown
Turn GPS coordinates into browsable collections named for the places you
visited, using Google.

**One-time setup:** create a Google Cloud project, enable the **Places API
(New)** and the **Geocoding API**, create an API key, and paste it into
**File → Plug-in Manager → Phone Geotagger → Google API key**. (These are
billable Google APIs; the plugin caches every location so each spot is looked
up only once.)

1. Select geotagged photos and run **Library → Plug-in Extras → Create
   Location Collections...**.
2. Choose the **collection name format** — a primary level (POI / City / State
   / Country) and an optional secondary level for context. The default is
   `POI, City`.
3. Each photo is named after the nearest notable place from Google (e.g.
   `Griffith Observatory, Los Angeles`), falling back to City / State / Country
   when there's no notable place nearby. All the collections live in a **Geo
   Locations** collection set.

These are regular collections (a snapshot of the photos you ran it on), so
re-run the command after geotagging more photos to fold them in. Locations are
cached locally, and very large selections are processed in bounded batches to
keep memory flat.
```

Also, in the "Credits" section, replace the line
`- Reverse geocoding by [OpenStreetMap Nominatim](https://nominatim.org/).`
with:

```markdown
- Place names and geocoding by [Google Maps Platform](https://developers.google.com/maps).
```

- [ ] **Step 2: Final full-suite run**

Run: `busted`
Expected: all pass (~95), `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: Google POI location collections + API key setup"
```
