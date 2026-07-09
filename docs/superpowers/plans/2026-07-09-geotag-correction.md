# Geotag Correction Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-command geotag-correction flow to the Phone Geotagger Lightroom plugin: find all photos sharing a bad geotag, then batch-correct the selection to a location chosen from Timeline history or a browser map picker.

**Architecture:** Four new Lightroom-independent core modules (`geo_group`, `coord_parse`, `candidate_finder`, `clipboard`) with busted unit tests, plus a Lightroom shell (two menu commands, a correction dialog, and a bundled Leaflet `mappicker.html` whose picked coordinate returns via the system clipboard). Follows the existing plugin's conventions exactly.

**Tech Stack:** Lua 5.1 (Lightroom runtime), Lightroom Classic SDK, Leaflet (vendored) + OpenStreetMap/Nominatim, busted for tests.

**Spec:** `docs/superpowers/specs/2026-07-09-geotag-correction-design.md`

## Global Constraints

- **Lua 5.1 compatibility everywhere** (no `goto`, no `table.unpack`, no `//`, no `%q` beyond strings).
- **Flat file layout inside `PhoneGeotagger.lrplugin/`** — Lua `require` resolves only the plugin root; no subdirectories for Lua modules. `mappicker.html`, `leaflet.js`, `leaflet.css` also live at the plugin root.
- **Core modules never call Lightroom's `import`** — standard Lua only: `geo_group.lua`, `coord_parse.lua`, `candidate_finder.lua`, `clipboard.lua`. Lightroom-dependent files: `FindGeotagGroupMenuItem.lua`, `CorrectGeotagMenuItem.lua`, `CorrectDialog.lua`, `plugin_paths.lua`, `Info.lua`.
- **Track/point shape** (shared with v1): `{ t = utc_seconds, lat = number, lon = number }`. GPS metadata from Lightroom is a table `{ latitude = number, longitude = number }`.
- Menu titles exactly: `Find Photos With This Geotag` and `Correct Geotag of Selection...`. Plugin id stays `com.github.mssadik73.phonegeotagger`.
- Defaults: grouping tolerance **25 m**; history candidate radius **500 m**, cap **10** nearest.
- Run tests with `busted` from the repo root. Commit after every passing task. Work on branch `feature/geotag-correction`.
- The current baseline suite is **46 passing**. New core-module tests add to it; the Lightroom-shell tasks must not reduce it.

---

### Task 1: geo_group module

**Files:**
- Create: `PhoneGeotagger.lrplugin/geo_group.lua`
- Test: `spec/geo_group_spec.lua`

**Interfaces:**
- Produces:
  - `geo_group.haversine(lat1, lon1, lat2, lon2)` → distance in meters (number).
  - `geo_group.filter_within(candidates, lat, lon, radius_m)` → new array. Each input candidate is a table with numeric `lat` and `lon` (plus any passthrough keys); output contains a shallow copy of each candidate whose distance ≤ `radius_m`, with an added `dist` (meters) key, sorted ascending by `dist`.

- [ ] **Step 1: Write the failing tests**

`spec/geo_group_spec.lua`:

```lua
local geo_group = require "geo_group"

describe("geo_group.haversine", function()
  it("is zero for identical points", function()
    assert.equals(0, geo_group.haversine(23.5, 90.4, 23.5, 90.4))
  end)

  it("computes ~111.2 km for one degree of longitude at the equator", function()
    local d = geo_group.haversine(0, 0, 0, 1)
    assert.near(111195, d, 100)
  end)

  it("computes ~111.2 km for one degree of latitude", function()
    local d = geo_group.haversine(0, 0, 1, 0)
    assert.near(111195, d, 100)
  end)

  it("computes a short distance in meters", function()
    -- ~0.001 deg latitude ~= 111 m
    local d = geo_group.haversine(23.5, 90.4, 23.501, 90.4)
    assert.near(111, d, 2)
  end)
end)

describe("geo_group.filter_within", function()
  local candidates = {
    { lat = 23.5000, lon = 90.4000, label = "A" },
    { lat = 23.5010, lon = 90.4000, label = "B" }, -- ~111 m north
    { lat = 23.6000, lon = 90.4000, label = "C" }, -- ~11 km north
  }

  it("keeps only points within the radius, nearest first, with dist", function()
    local out = geo_group.filter_within(candidates, 23.5000, 90.4000, 500)
    assert.equals(2, #out)
    assert.equals("A", out[1].label)
    assert.equals("B", out[2].label)
    assert.equals(0, out[1].dist)
    assert.near(111, out[2].dist, 2)
  end)

  it("returns an empty list when nothing is in range", function()
    local out = geo_group.filter_within(candidates, 0, 0, 500)
    assert.equals(0, #out)
  end)

  it("does not mutate the input candidates", function()
    geo_group.filter_within(candidates, 23.5, 90.4, 500)
    assert.is_nil(candidates[1].dist)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/geo_group_spec.lua`
Expected: FAIL — `module 'geo_group' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/geo_group.lua`:

```lua
-- Great-circle distance and radius filtering for geotag grouping/correction.

local geo_group = {}

local R = 6371000 -- mean Earth radius, meters
local RAD = math.pi / 180

-- Distance in meters between two lat/lon pairs (degrees).
function geo_group.haversine(lat1, lon1, lat2, lon2)
  local dlat = (lat2 - lat1) * RAD
  local dlon = (lon2 - lon1) * RAD
  local a = math.sin(dlat / 2) ^ 2
    + math.cos(lat1 * RAD) * math.cos(lat2 * RAD) * math.sin(dlon / 2) ^ 2
  local c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
  return R * c
end

-- Returns a new array of shallow-copied candidates within radius_m of
-- (lat, lon), each with an added `dist` (meters), sorted nearest first.
function geo_group.filter_within(candidates, lat, lon, radius_m)
  local out = {}
  for _, c in ipairs(candidates) do
    local d = geo_group.haversine(lat, lon, c.lat, c.lon)
    if d <= radius_m then
      local copy = {}
      for k, v in pairs(c) do copy[k] = v end
      copy.dist = d
      out[#out + 1] = copy
    end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end

return geo_group
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/geo_group_spec.lua`
Expected: `7 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/geo_group.lua spec/geo_group_spec.lua
git commit -m "feat: geo_group haversine distance and radius filtering"
```

---

### Task 2: coord_parse module

**Files:**
- Create: `PhoneGeotagger.lrplugin/coord_parse.lua`
- Test: `spec/coord_parse_spec.lua`

**Interfaces:**
- Produces: `coord_parse.parse(text)` → `lat, lon` (numbers) on success; `nil, error_message` on failure. Accepts `"lat, lon"` and `"lat lon"` with surrounding whitespace. Rejects non-strings, unparseable text, and out-of-range values (`|lat| ≤ 90`, `|lon| ≤ 180`).

- [ ] **Step 1: Write the failing tests**

`spec/coord_parse_spec.lua`:

```lua
local coord_parse = require "coord_parse"

describe("coord_parse.parse", function()
  it("parses comma-separated coordinates", function()
    local lat, lon = coord_parse.parse("23.8103, 90.4125")
    assert.near(23.8103, lat, 1e-9)
    assert.near(90.4125, lon, 1e-9)
  end)

  it("parses whitespace-separated coordinates", function()
    local lat, lon = coord_parse.parse("23.8103   90.4125")
    assert.near(23.8103, lat, 1e-9)
    assert.near(90.4125, lon, 1e-9)
  end)

  it("tolerates surrounding whitespace and negatives", function()
    local lat, lon = coord_parse.parse("  -33.8688,151.2093  ")
    assert.near(-33.8688, lat, 1e-9)
    assert.near(151.2093, lon, 1e-9)
  end)

  it("rejects a latitude beyond ±90", function()
    local lat, err = coord_parse.parse("91.0, 10.0")
    assert.is_nil(lat)
    assert.is_string(err)
  end)

  it("rejects a longitude beyond ±180", function()
    local lat, err = coord_parse.parse("10.0, 200.0")
    assert.is_nil(lat)
    assert.is_string(err)
  end)

  it("rejects unparseable text", function()
    local lat, err = coord_parse.parse("somewhere nice")
    assert.is_nil(lat)
    assert.is_string(err)
  end)

  it("rejects a single number", function()
    local lat, err = coord_parse.parse("23.8103")
    assert.is_nil(lat)
    assert.is_string(err)
  end)

  it("rejects non-strings", function()
    local lat, err = coord_parse.parse(nil)
    assert.is_nil(lat)
    assert.is_string(err)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/coord_parse_spec.lua`
Expected: FAIL — `module 'coord_parse' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/coord_parse.lua`:

```lua
-- Parses a "lat, lon" (or "lat lon") string into numeric coordinates.

local coord_parse = {}

-- Returns lat, lon — or nil, error_message.
function coord_parse.parse(text)
  if type(text) ~= "string" then
    return nil, "no coordinates to parse"
  end
  local lat_s, lon_s = text:match("^%s*(%-?%d+%.?%d*)%s*[, ]%s*(%-?%d+%.?%d*)%s*$")
  if not lat_s then
    return nil, "could not read coordinates from: " .. text
  end
  local lat, lon = tonumber(lat_s), tonumber(lon_s)
  if not lat or not lon then
    return nil, "could not read coordinates from: " .. text
  end
  if lat < -90 or lat > 90 then
    return nil, "latitude out of range: " .. lat_s
  end
  if lon < -180 or lon > 180 then
    return nil, "longitude out of range: " .. lon_s
  end
  return lat, lon
end

return coord_parse
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/coord_parse_spec.lua`
Expected: `8 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/coord_parse.lua spec/coord_parse_spec.lua
git commit -m "feat: coord_parse for pasted/clipboard lat-lon strings"
```

---

### Task 3: candidate_finder module

**Files:**
- Create: `PhoneGeotagger.lrplugin/candidate_finder.lua`
- Test: `spec/candidate_finder_spec.lua`

**Interfaces:**
- Consumes: `geo_group.filter_within` (Task 1).
- Produces: `candidate_finder.find(points, lat, lon, opts)` → array of `{ lat, lon, dist }` (nearest first), where `points` is a `{t, lat, lon}` array (the history cache), `opts = { radius_m = 500, max = 10 }` (both optional with those defaults). Candidates are deduped by coordinate rounded to 5 decimals (≈1 m); the current coordinate itself (dist 0, i.e. the wrong tag if it happens to be in history) is not special-cased out — callers show all. Capped at `opts.max`.

- [ ] **Step 1: Write the failing tests**

`spec/candidate_finder_spec.lua`:

```lua
local candidate_finder = require "candidate_finder"

describe("candidate_finder.find", function()
  local points = {
    { t = 1, lat = 23.5000, lon = 90.4000 },
    { t = 2, lat = 23.5000, lon = 90.4000 }, -- exact duplicate coordinate
    { t = 3, lat = 23.5010, lon = 90.4000 }, -- ~111 m
    { t = 4, lat = 23.6000, lon = 90.4000 }, -- ~11 km, out of default radius
  }

  it("returns nearby points deduped by coordinate, nearest first", function()
    local out = candidate_finder.find(points, 23.5000, 90.4000, {})
    assert.equals(2, #out)                 -- duplicate collapsed, far point dropped
    assert.near(23.5000, out[1].lat, 1e-9)
    assert.equals(0, out[1].dist)
    assert.near(23.5010, out[2].lat, 1e-9)
    assert.near(111, out[2].dist, 2)
  end)

  it("honors a custom radius", function()
    local out = candidate_finder.find(points, 23.5000, 90.4000, { radius_m = 20000 })
    assert.equals(3, #out)                 -- now includes the ~11 km point
  end)

  it("caps the result count", function()
    local many = {}
    for i = 1, 30 do
      many[i] = { t = i, lat = 23.5 + i * 0.0001, lon = 90.4 }
    end
    local out = candidate_finder.find(many, 23.5, 90.4, { radius_m = 100000, max = 5 })
    assert.equals(5, #out)
  end)

  it("returns an empty list when history is empty", function()
    assert.same({}, candidate_finder.find({}, 23.5, 90.4, {}))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/candidate_finder_spec.lua`
Expected: FAIL — `module 'candidate_finder' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/candidate_finder.lua`:

```lua
-- Finds nearby history points to offer as corrected-location candidates.

local geo_group = require "geo_group"

local candidate_finder = {}

local function key(lat, lon)
  return string.format("%.5f,%.5f", lat, lon)
end

-- points: { {t, lat, lon}, ... }. opts: { radius_m = 500, max = 10 }.
-- Returns { {lat, lon, dist}, ... } nearest first, deduped by ~1 m coordinate.
function candidate_finder.find(points, lat, lon, opts)
  opts = opts or {}
  local radius_m = opts.radius_m or 500
  local max = opts.max or 10

  local seen = {}
  local unique = {}
  for _, p in ipairs(points) do
    local k = key(p.lat, p.lon)
    if not seen[k] then
      seen[k] = true
      unique[#unique + 1] = { lat = p.lat, lon = p.lon }
    end
  end

  local within = geo_group.filter_within(unique, lat, lon, radius_m)
  local out = {}
  for i = 1, math.min(max, #within) do
    out[i] = { lat = within[i].lat, lon = within[i].lon, dist = within[i].dist }
  end
  return out
end

return candidate_finder
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/candidate_finder_spec.lua`
Expected: `4 successes / 0 failures`

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/candidate_finder.lua spec/candidate_finder_spec.lua
git commit -m "feat: candidate_finder for nearby history corrections"
```

---

### Task 4: clipboard module

**Files:**
- Create: `PhoneGeotagger.lrplugin/clipboard.lua`
- Test: `spec/clipboard_spec.lua`

**Interfaces:**
- Consumes: an injected `exec(command) → exit_status, output_text` (the real one is `LrExec.execute` from v1; tests use a fake).
- Produces:
  - `clipboard.read_command(is_windows)` → the platform clipboard-read command string.
  - `clipboard.read(exec, is_windows)` → the clipboard text with surrounding whitespace/newlines trimmed (`""` when the command produced no output).

- [ ] **Step 1: Write the failing tests**

`spec/clipboard_spec.lua`:

```lua
local clipboard = require "clipboard"

local function fake_exec(output)
  local calls = {}
  return function(cmd)
    calls[#calls + 1] = cmd
    return 0, output
  end, calls
end

describe("clipboard", function()
  it("uses pbpaste on macOS", function()
    assert.equals("pbpaste", clipboard.read_command(false))
  end)

  it("uses PowerShell Get-Clipboard on Windows", function()
    assert.equals('powershell -command "Get-Clipboard"', clipboard.read_command(true))
  end)

  it("reads and trims the clipboard text", function()
    local exec, calls = fake_exec("23.8103, 90.4125\n")
    assert.equals("23.8103, 90.4125", clipboard.read(exec, false))
    assert.equals("pbpaste", calls[1])
  end)

  it("returns empty string for empty clipboard", function()
    local exec = fake_exec("")
    assert.equals("", clipboard.read(exec, false))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/clipboard_spec.lua`
Expected: FAIL — `module 'clipboard' not found`

- [ ] **Step 3: Implement**

`PhoneGeotagger.lrplugin/clipboard.lua`:

```lua
-- Reads the system clipboard via an injected exec (Lightroom-free, testable).

local clipboard = {}

function clipboard.read_command(is_windows)
  if is_windows then
    return 'powershell -command "Get-Clipboard"'
  end
  return "pbpaste"
end

-- exec: function(command) -> exit_status, output_text
-- Returns the clipboard text, trimmed of surrounding whitespace/newlines.
function clipboard.read(exec, is_windows)
  local _, out = exec(clipboard.read_command(is_windows))
  out = out or ""
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

return clipboard
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/clipboard_spec.lua`
Expected: `4 successes / 0 failures`

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: all specs pass (46 baseline + 23 new = 69), `0 failures`

- [ ] **Step 6: Commit**

```bash
git add PhoneGeotagger.lrplugin/clipboard.lua spec/clipboard_spec.lua
git commit -m "feat: clipboard read via injected exec for map hand-off"
```

---

### Task 5: Bundled Leaflet map picker (mappicker.html)

**Files:**
- Create: `PhoneGeotagger.lrplugin/mappicker.html`
- Create: `PhoneGeotagger.lrplugin/leaflet.js` (vendored)
- Create: `PhoneGeotagger.lrplugin/leaflet.css` (vendored)

**Interfaces:**
- Produces: a browser page opened as `file://.../mappicker.html?lat=<lat>&lon=<lon>`. Opens centered on that coordinate with a draggable marker on it, pre-copies `"lat, lon"` to the clipboard, and re-copies on marker drag / map click / search selection, showing a "Copied ✓" confirmation. No busted test — verified manually in a browser.

- [ ] **Step 1: Vendor Leaflet**

```bash
cd /Users/mssadik/projects/GeoTag
curl -fsSL -o PhoneGeotagger.lrplugin/leaflet.js  https://unpkg.com/leaflet@1.9.4/dist/leaflet.js
curl -fsSL -o PhoneGeotagger.lrplugin/leaflet.css https://unpkg.com/leaflet@1.9.4/dist/leaflet.css
grep -q "Leaflet" PhoneGeotagger.lrplugin/leaflet.js && echo OK
```

Expected: `OK`. (Leaflet is BSD-2-Clause — compatible with this repo's MIT license; credit it in the README task.)

- [ ] **Step 2: Write mappicker.html**

`PhoneGeotagger.lrplugin/mappicker.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Phone Geotagger — pick a location</title>
  <link rel="stylesheet" href="leaflet.css" />
  <script src="leaflet.js"></script>
  <style>
    html, body { margin: 0; height: 100%; font-family: sans-serif; }
    #bar { padding: 8px; background: #222; color: #eee; display: flex; gap: 8px; align-items: center; }
    #bar input { flex: 1; padding: 6px; }
    #status { padding: 6px 8px; background: #143; color: #cfc; min-height: 1em; }
    #map { height: calc(100% - 84px); }
    .pin { width: 18px; height: 18px; border-radius: 50% 50% 50% 0;
      background: #e33; border: 2px solid #fff; transform: rotate(-45deg); }
  </style>
</head>
<body>
  <div id="bar">
    <input id="q" type="text" placeholder="Search a place, then press Enter" />
    <button id="go">Search</button>
  </div>
  <div id="status">Drag the pin to the correct spot, or click the map.</div>
  <div id="map"></div>
  <script>
    function param(name, fallback) {
      var m = new RegExp("[?&]" + name + "=([^&]+)").exec(location.search);
      return m ? parseFloat(decodeURIComponent(m[1])) : fallback;
    }
    var lat = param("lat", 0), lon = param("lon", 0);

    var map = L.map("map").setView([lat, lon], 16);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19, attribution: "© OpenStreetMap contributors"
    }).addTo(map);

    var icon = L.divIcon({ className: "", html: '<div class="pin"></div>',
      iconSize: [18, 18], iconAnchor: [9, 18] });
    var marker = L.marker([lat, lon], { draggable: true, icon: icon }).addTo(map);

    function copy(text) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(function () { legacyCopy(text); });
      } else { legacyCopy(text); }
    }
    function legacyCopy(text) {
      var ta = document.createElement("textarea");
      ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
    }
    function pick(ll) {
      var text = ll.lat.toFixed(6) + ", " + ll.lng.toFixed(6);
      copy(text);
      document.getElementById("status").textContent =
        “Copied ✓  “ + text + “  — switch back to Lightroom and click \”Use location from map\”.”;
    }

    pick(marker.getLatLng());
    marker.on("dragend", function () { pick(marker.getLatLng()); });
    map.on("click", function (e) { marker.setLatLng(e.latlng); pick(e.latlng); });

    function search() {
      var q = document.getElementById("q").value.trim();
      if (!q) return;
      fetch("https://nominatim.openstreetmap.org/search?format=json&limit=1&q=" +
        encodeURIComponent(q))
        .then(function (r) { return r.json(); })
        .then(function (results) {
          if (!results.length) {
            document.getElementById("status").textContent = "No match for: " + q;
            return;
          }
          var ll = L.latLng(parseFloat(results[0].lat), parseFloat(results[0].lon));
          map.setView(ll, 16); marker.setLatLng(ll); pick(ll);
        })
        .catch(function () {
          document.getElementById("status").textContent =
            "Search failed (no connection?). You can still drag the pin.";
        });
    }
    document.getElementById("go").addEventListener("click", search);
    document.getElementById("q").addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); search(); }
    });
  </script>
</body>
</html>
```

- [ ] **Step 3: Manual verification in a browser**

```bash
open "file://$(pwd)/PhoneGeotagger.lrplugin/mappicker.html?lat=23.8103&lon=90.4125"
```

Confirm: the map opens centered on that point with a red pin on it; the status bar reads "Copied ✓ 23.810300, 90.412500 …"; dragging the pin updates the status and (paste anywhere to check) the clipboard; clicking the map moves the pin and re-copies; typing a place name + Enter recenters and re-copies. If offline, the pin/drag still work and search shows the "no connection" message.

- [ ] **Step 4: Commit**

```bash
git add PhoneGeotagger.lrplugin/mappicker.html PhoneGeotagger.lrplugin/leaflet.js PhoneGeotagger.lrplugin/leaflet.css
git commit -m "feat: bundled Leaflet map picker with clipboard hand-off"
```

---

### Task 6: Find Photos With This Geotag command

**Files:**
- Create: `PhoneGeotagger.lrplugin/FindGeotagGroupMenuItem.lua`
- Modify: `PhoneGeotagger.lrplugin/Info.lua` (add one menu entry)

**Interfaces:**
- Consumes: `geo_group.haversine` (Task 1); Lightroom SDK (`catalog:getTargetPhoto`, `getRawMetadata("gps")`, `catalog:getAllPhotos`, `catalog:batchGetRawMetadata`, `catalog:setSelectedPhotos`).
- Produces: the first user-facing command. No busted spec — verified manually in Lightroom; syntax-checked with `luac -p`.

- [ ] **Step 1: Add the menu entry to Info.lua**

In `PhoneGeotagger.lrplugin/Info.lua`, change the `LrLibraryMenuItems` table so it holds the existing entry plus a new one:

```lua
  LrLibraryMenuItems = {
    {
      title = "Geotag from Phone Timeline...",
      file = "GeotagMenuItem.lua",
    },
    {
      title = "Find Photos With This Geotag",
      file = "FindGeotagGroupMenuItem.lua",
    },
  },
```

- [ ] **Step 2: Write FindGeotagGroupMenuItem.lua**

`PhoneGeotagger.lrplugin/FindGeotagGroupMenuItem.lua`:

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

local geo_group = require "geo_group"

local TOLERANCE_M = 25

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local example = catalog:getTargetPhoto()
  if not example then
    LrDialogs.message("Find Photos With This Geotag",
      "Select one photo that has the geotag you want to match.", "info")
    return
  end

  local gps = example:getRawMetadata("gps")
  if not gps or not gps.latitude then
    LrDialogs.message("Find Photos With This Geotag",
      "This photo has no geotag to match.", "info")
    return
  end

  local all = catalog:getAllPhotos()
  local meta = catalog:batchGetRawMetadata(all, { "gps" })
  local matches = {}
  for photo, m in pairs(meta) do
    local g = m.gps
    if g and g.latitude then
      if geo_group.haversine(gps.latitude, gps.longitude, g.latitude, g.longitude)
          <= TOLERANCE_M then
        matches[#matches + 1] = photo
      end
    end
  end

  catalog:setSelectedPhotos(matches[1] or example, matches)
  LrDialogs.message("Find Photos With This Geotag",
    string.format("%d photo(s) share this geotag (within %d m). Review the "
      .. "selection and deselect any that don't belong, then run "
      .. "\"Correct Geotag of Selection...\".", #matches, TOLERANCE_M), "info")
end)
```

- [ ] **Step 3: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/FindGeotagGroupMenuItem.lua
luac -p PhoneGeotagger.lrplugin/Info.lua
busted
```
Expected: `luac` prints nothing (clean); `busted` still green (69 tests).

- [ ] **Step 4: Manual test in Lightroom Classic** (deferred to the project owner; note in report)

1. Plug-in Manager → Reload Plug-in.
2. Select a photo with a known geotag → Library → Plug-in Extras → **Find Photos With This Geotag** → the grid selection expands to all photos within 25 m and the count dialog appears.
3. Select a photo with no GPS → run → "This photo has no geotag to match."
4. With no photo active → run → "Select one photo…".

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/FindGeotagGroupMenuItem.lua PhoneGeotagger.lrplugin/Info.lua
git commit -m "feat: Find Photos With This Geotag command"
```

---

### Task 7: Correct Geotag of Selection command + dialog

**Files:**
- Create: `PhoneGeotagger.lrplugin/plugin_paths.lua`
- Create: `PhoneGeotagger.lrplugin/CorrectDialog.lua`
- Create: `PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua`
- Modify: `PhoneGeotagger.lrplugin/Info.lua` (add one menu entry)
- Modify: `PhoneGeotagger.lrplugin/GeotagMenuItem.lua` (reuse the shared cache-path helper)

**Interfaces:**
- Consumes: `candidate_finder.find` (Task 3), `clipboard.read` (Task 4), `coord_parse.parse` (Task 2), `history_cache.load` (v1), `LrExec.execute` (v1), the bundled `mappicker.html` (Task 5); Lightroom SDK (`getTargetPhotos`, `getRawMetadata`, `withWriteAccessDo`, `setRawMetadata`, `LrView`, `LrBinding`, `LrHttp.openUrlInBrowser`, `LrPathUtils`).
- Produces: the second user-facing command, completing the feature. No busted spec — manual in Lightroom; syntax-checked with `luac -p`.

- [ ] **Step 1: Extract the shared cache-path helper**

`PhoneGeotagger.lrplugin/plugin_paths.lua` (new):

```lua
-- Shared filesystem paths for the plugin (Lightroom-dependent).

local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local plugin_paths = {}

-- Absolute path to the accumulated history cache CSV.
function plugin_paths.cache_path()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return LrPathUtils.child(dir, "history.csv")
end

return plugin_paths
```

In `PhoneGeotagger.lrplugin/GeotagMenuItem.lua`, remove its local `cache_path` function definition and the now-unused `LrPathUtils`/`LrFileUtils` imports **only if** they are not used elsewhere in that file (they are used elsewhere — keep the imports), and replace the `local function cache_path() ... end` block with a require. Concretely: delete the `local function cache_path()` definition, add near the other requires:

```lua
local plugin_paths = require "plugin_paths"
```

and change the single call site `local cpath = cache_path()` to `local cpath = plugin_paths.cache_path()`. Leave all other lines unchanged.

- [ ] **Step 2: Write CorrectDialog.lua**

`PhoneGeotagger.lrplugin/CorrectDialog.lua`:

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local clipboard = require "clipboard"
local coord_parse = require "coord_parse"
local LrExec = require "LrExec"

local CorrectDialog = {}

local function fmt(lat, lon)
  return string.format("%.5f, %.5f", lat, lon)
end

-- args: { photo_count, current_lat, current_lon, candidates }
-- candidates: { {lat, lon, dist}, ... }
-- Returns { lat = number, lon = number } or nil on cancel / no pick.
function CorrectDialog.run(args)
  local result

  LrFunctionContext.callWithContext("CorrectDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)

    -- Build candidate popup items; source defaults to history if any exist.
    local items = {}
    for i, c in ipairs(args.candidates) do
      items[i] = {
        title = string.format("%s   (~%d m away)", fmt(c.lat, c.lon), math.floor(c.dist + 0.5)),
        value = i,
      }
    end
    props.has_candidates = #items > 0
    props.source = props.has_candidates and "history" or "map"
    props.candidate_index = 1
    props.map_label = "(none yet)"
    props.map_lat = nil
    props.map_lon = nil

    local history_row
    if props.has_candidates then
      history_row = f:row {
        f:radio_button { title = "From Timeline history:", value = bind "source", checked_value = "history" },
        f:popup_menu { items = items, value = bind "candidate_index" },
      }
    else
      history_row = f:static_text { title = "No Timeline history found near this location." }
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text { title = "Current tag: " .. fmt(args.current_lat, args.current_lon) },
      history_row,
      f:row {
        f:radio_button { title = "From map:", value = bind "source", checked_value = "map" },
        f:push_button {
          title = "Open map picker",
          action = function()
            local html = LrPathUtils.child(_PLUGIN.path, "mappicker.html")
            local url = "file://" .. html .. "?lat=" .. tostring(args.current_lat)
              .. "&lon=" .. tostring(args.current_lon)
            LrHttp.openUrlInBrowser(url)
          end,
        },
      },
      f:row {
        f:push_button {
          title = "Use location from map",
          action = function()
            LrTasks.startAsyncTask(function()
              local text = clipboard.read(LrExec.execute, WIN_ENV == true)
              local lat, lon = coord_parse.parse(text)
              if not lat then
                LrDialogs.message("Use location from map",
                  "No coordinates on the clipboard yet. In the map, drag the pin "
                  .. "or click the correct spot, then try again.", "warning")
                return
              end
              props.map_lat = lat
              props.map_lon = lon
              props.map_label = fmt(lat, lon)
              props.source = "map"
            end)
          end,
        },
        f:static_text { title = bind "map_label", fill_horizontal = 1 },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Correct Geotag",
      contents = contents,
      actionVerb = string.format("Apply to %d photo(s)", args.photo_count),
    }
    if action ~= "ok" then return end

    if props.source == "history" and props.has_candidates then
      local c = args.candidates[props.candidate_index]
      result = { lat = c.lat, lon = c.lon }
    elseif props.source == "map" and props.map_lat then
      result = { lat = props.map_lat, lon = props.map_lon }
    else
      LrDialogs.message("Correct Geotag",
        "No corrected location was chosen. Pick a history candidate or use the "
        .. "map picker first.", "warning")
    end
  end)

  return result
end

return CorrectDialog
```

- [ ] **Step 3: Write CorrectGeotagMenuItem.lua**

`PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua`:

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

local history_cache = require "history_cache"
local candidate_finder = require "candidate_finder"
local plugin_paths = require "plugin_paths"
local CorrectDialog = require "CorrectDialog"

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local photos = catalog:getTargetPhotos()
  if not photos or #photos == 0 then
    LrDialogs.message("Correct Geotag",
      "Select the photos to correct in the Library grid first.", "info")
    return
  end

  local gps = photos[1]:getRawMetadata("gps")
  if not gps or not gps.latitude then
    LrDialogs.message("Correct Geotag",
      "The first selected photo has no geotag. Select photos that already "
      .. "have the tag you want to correct.", "info")
    return
  end

  local points = history_cache.load(plugin_paths.cache_path())
  local candidates = candidate_finder.find(points, gps.latitude, gps.longitude,
    { radius_m = 500, max = 10 })

  local result = CorrectDialog.run {
    photo_count = #photos,
    current_lat = gps.latitude,
    current_lon = gps.longitude,
    candidates = candidates,
  }
  if not result then return end

  catalog:withWriteAccessDo("Correct geotag", function()
    for _, photo in ipairs(photos) do
      photo:setRawMetadata("gps", { latitude = result.lat, longitude = result.lon })
    end
  end)

  LrDialogs.message("Correct Geotag",
    string.format("%d photo(s) re-tagged to %.5f, %.5f.",
      #photos, result.lat, result.lon), "info")
end)
```

- [ ] **Step 4: Add the menu entry to Info.lua**

In `PhoneGeotagger.lrplugin/Info.lua`, add a third `LrLibraryMenuItems` entry after the "Find Photos With This Geotag" one:

```lua
    {
      title = "Correct Geotag of Selection...",
      file = "CorrectGeotagMenuItem.lua",
    },
```

- [ ] **Step 5: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/plugin_paths.lua
luac -p PhoneGeotagger.lrplugin/CorrectDialog.lua
luac -p PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua
luac -p PhoneGeotagger.lrplugin/GeotagMenuItem.lua
luac -p PhoneGeotagger.lrplugin/Info.lua
busted
```
Expected: all `luac` clean; `busted` still green (69 tests).

- [ ] **Step 6: Manual test in Lightroom Classic** (deferred to the project owner; note in report)

1. Plug-in Manager → Reload Plug-in.
2. Select a group of geotagged photos → Plug-in Extras → **Correct Geotag of Selection...** → dialog shows the current tag, a history candidate popup (if any), and the map row.
3. Pick a history candidate → Apply → summary; verify new coordinates in the Metadata panel and Map module.
4. Re-run → **Open map picker** → browser opens on the current location with a draggable pin → drag to the true spot → back in Lightroom click **Use location from map** → the picked coordinate appears → Apply → verify.
5. Run with the first photo lacking GPS → the "no geotag" message; run with nothing selected → the "select photos first" message.
6. Confirm the v1 "Geotag from Phone Timeline..." command still works (shared `plugin_paths.cache_path()` refactor didn't break it).

- [ ] **Step 7: Commit**

```bash
git add PhoneGeotagger.lrplugin/plugin_paths.lua PhoneGeotagger.lrplugin/CorrectDialog.lua PhoneGeotagger.lrplugin/CorrectGeotagMenuItem.lua PhoneGeotagger.lrplugin/Info.lua PhoneGeotagger.lrplugin/GeotagMenuItem.lua
git commit -m "feat: Correct Geotag of Selection command with history + map picker"
```

---

### Task 8: README update for the correction feature

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the finished feature. Documents both new commands for GitHub users.

- [ ] **Step 1: Add a "Correcting a wrong geotag" section**

Insert this section into `README.md` immediately after the existing "How it works" section:

```markdown
## Correcting a wrong geotag

Google Timeline sometimes snaps a location to a nearby-but-wrong place. Two
commands fix that:

1. Select one photo carrying the bad tag and run **Library → Plug-in Extras →
   Find Photos With This Geotag**. Every photo within 25 m of it is selected
   in the grid. Deselect any that don't belong.
2. Run **Correct Geotag of Selection...**. Choose the true location either
   from nearby Timeline history points or with the built-in map picker:
   **Open map picker** launches a map in your browser with a pin on the
   current location — drag it to the correct spot (or search a place), then
   back in Lightroom click **Use location from map**. Click **Apply** to write
   the corrected coordinate to every selected photo.

The map picker hands the coordinate back through your system clipboard, so no
typing is needed. The corrected coordinates are written to the catalog; use
**Metadata → Save Metadata to File** to push them into your files/XMP.
```

Also add a line to the "Credits" section:

```markdown
- Map picker built with [Leaflet](https://leafletjs.com/) (BSD-2-Clause) and
  [OpenStreetMap](https://www.openstreetmap.org/) tiles and search.
```

- [ ] **Step 2: Final full-suite run**

Run: `busted`
Expected: all specs pass (69), `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document the geotag correction commands"
```
