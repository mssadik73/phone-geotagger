# Place Name Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an offline "Clean Up Place Names" command that reconciles City/State/Country across photos at the same place, so a place yields one collection instead of splitting.

**Architecture:** A pure, unit-tested core module `place_reconcile.lua` does the grouping (POI + GPS grid cell), the per-field majority vote, and the earliest-capture-time tie-break, returning per-record resolved places plus group/conflict counts. Two thin Lightroom-shell files drive it: `CleanupDialog.lua` (radius + launch) and `CleanupMenuItem.lua` (batch-read IPTC/GPS/time → reconcile → write only changed fields → summary). `Info.lua` registers the menu item.

**Tech Stack:** Lua 5.1 (Lightroom runtime; local dev Lua 5.5), busted, Lightroom Classic SDK.

## Global Constraints

- Lua 5.1 compatible; flat file layout under `PhoneGeotagger.lrplugin/`; core modules are Lightroom-free and busted-tested, shell files (`*Dialog.lua`, `*MenuItem.lua`, `Info.lua`) `import` the SDK and are verified manually by the owner.
- IPTC keys: read via `batchGetFormattedMetadata` keys `location`/`city`/`stateProvince`/`country`; write via `setRawMetadata` keys `city`/`stateProvince`/`country` (state's read AND write key is `stateProvince` — there is no `state` key). `location` (POI) and `gps` are never modified by this feature.
- Grid constant `KM_PER_DEG = 111`, flat for both lat and lon (no cos-latitude correction).
- Cluster radius default `2` km, remembered in `prefs.cleanup_radius_km`.
- Majority vote is per-field over non-empty values; ties broken by earliest `dateTimeOriginalISO8601` (missing time sorts last).
- All catalog writes in one `withWriteAccessDo`.

---

### Task 1: place_reconcile core module

**Files:**
- Create: `PhoneGeotagger.lrplugin/place_reconcile.lua`
- Test: `spec/place_reconcile_spec.lua`

**Interfaces:**
- Produces:
  - `place_reconcile.cell(lat, lon, radius_km)` → `lat_cell, lon_cell` (integers).
  - `place_reconcile.group_key(poi, lat, lon, radius_km)` → string key (nil/empty POI → `""` bucket, POI trimmed).
  - `place_reconcile.reconcile(records, radius_km)` → `out, stats` where `records` is an array of `{ poi, city, state, country, lat, lon, time }` (`time` a sortable string or nil); `out` is an array (same order/length) of `{ city, state, country }` (any field may be nil); `stats` is `{ groups, conflicts }`.

- [ ] **Step 1: Write the failing tests**

Create `spec/place_reconcile_spec.lua`:

```lua
local pr = require "place_reconcile"

describe("place_reconcile.cell", function()
  it("puts nearby points in the same cell and far points in different cells", function()
    -- radius 2km -> cell_deg = 2/111 ~= 0.018 deg
    local a1, a2 = pr.cell(64.0000, -20.0000, 2)
    local b1, b2 = pr.cell(64.0050, -20.0050, 2)  -- ~0.5km away
    assert.equals(a1, b1)
    assert.equals(a2, b2)
    local c1 = pr.cell(64.5000, -20.0000, 2)      -- ~55km north
    assert.is_not.equal(a1, c1)
  end)
end)

describe("place_reconcile.group_key", function()
  it("separates the same POI when far apart", function()
    assert.is_not.equal(
      pr.group_key("Hella", 63.83, -20.38, 2),
      pr.group_key("Hella", 64.50, -20.38, 2))
  end)
  it("merges the same POI when close", function()
    assert.equals(
      pr.group_key("Hella", 63.8300, -20.3800, 2),
      pr.group_key(" Hella ", 63.8310, -20.3810, 2))  -- trimmed + ~0.1km
  end)
  it("buckets empty/nil POI together by cell", function()
    assert.equals(
      pr.group_key(nil, 63.8300, -20.3800, 2),
      pr.group_key("", 63.8305, -20.3805, 2))
  end)
end)

describe("place_reconcile.reconcile", function()
  local function rec(poi, city, state, country, lat, lon, time)
    return { poi = poi, city = city, state = state, country = country,
             lat = lat, lon = lon, time = time }
  end

  it("picks the plurality value per field and rewrites the whole group", function()
    -- Iceland x12 vs 'Rangarthing ytra' x2 -> Iceland for all 14
    local records = {}
    for i = 1, 12 do
      records[i] = rec("Hella", "Hella", "South", "Iceland", 63.83, -20.38,
        string.format("2026-06-01T10:%02d:00", i))
    end
    records[13] = rec("Hella", "Hella", "South", "Rangarthing ytra", 63.8301, -20.3801, "2026-06-01T09:00:00")
    records[14] = rec("Hella", "Hella", "South", "Rangarthing ytra", 63.8302, -20.3802, "2026-06-01T09:01:00")
    local out, stats = pr.reconcile(records, 2)
    for i = 1, 14 do assert.equals("Iceland", out[i].country) end
    assert.equals(1, stats.groups)
    assert.equals(1, stats.conflicts)
  end)

  it("breaks a tie by earliest capture time", function()
    -- 2 vs 2 on country; the earliest-timed photo carries 'Alpha'
    local records = {
      rec("P", "C", "S", "Beta",  10.0, 10.0, "2026-06-01T12:00:00"),
      rec("P", "C", "S", "Beta",  10.0, 10.0, "2026-06-01T11:00:00"),
      rec("P", "C", "S", "Alpha", 10.0, 10.0, "2026-06-01T08:00:00"),  -- earliest
      rec("P", "C", "S", "Alpha", 10.0, 10.0, "2026-06-01T09:00:00"),
    }
    local out = pr.reconcile(records, 2)
    for i = 1, 4 do assert.equals("Alpha", out[i].country) end
  end)

  it("fills blanks from the group winner", function()
    local records = {
      rec("P", "Town", "State", "Country", 10.0, 10.0, "t1"),
      rec("P", nil,    nil,     nil,       10.0, 10.0, "t2"),
    }
    local out = pr.reconcile(records, 2)
    assert.equals("Town", out[2].city)
    assert.equals("State", out[2].state)
    assert.equals("Country", out[2].country)
  end)

  it("leaves a field nil when empty across the whole group", function()
    local records = {
      rec("P", nil, nil, "Country", 10.0, 10.0, "t1"),
      rec("P", nil, nil, "Country", 10.0, 10.0, "t2"),
    }
    local out, stats = pr.reconcile(records, 2)
    assert.is_nil(out[1].city)
    assert.is_nil(out[1].state)
    assert.equals("Country", out[1].country)
    assert.equals(0, stats.conflicts)  -- no field had 2+ distinct values
  end)

  it("treats empty string like nil (not a vote)", function()
    local records = {
      rec("P", "", "", "Iceland", 10.0, 10.0, "t1"),
      rec("P", "Vik", "South", "Iceland", 10.0, 10.0, "t2"),
    }
    local out = pr.reconcile(records, 2)
    assert.equals("Vik", out[1].city)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted spec/place_reconcile_spec.lua`
Expected: FAIL — `module 'place_reconcile' not found`.

- [ ] **Step 3: Write the implementation**

Create `PhoneGeotagger.lrplugin/place_reconcile.lua`:

```lua
-- Reconciles City/State/Country across photos at the same place. Pure and
-- Lightroom-free: grouping (POI + GPS grid cell), per-field majority vote,
-- earliest-capture-time tie-break.

local place_reconcile = {}

local KM_PER_DEG = 111
local FIELDS = { "city", "state", "country" }

local function trim(s)
  if s == nil then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function present(v)
  return v ~= nil and v ~= ""
end

-- Grid cell indices for a coordinate at the given cluster radius.
function place_reconcile.cell(lat, lon, radius_km)
  local cell_deg = radius_km / KM_PER_DEG
  return math.floor(lat / cell_deg), math.floor(lon / cell_deg)
end

-- Group key: trimmed POI + GPS cell. Empty/nil POI -> "" bucket.
function place_reconcile.group_key(poi, lat, lon, radius_km)
  local lc, oc = place_reconcile.cell(lat, lon, radius_km)
  return trim(poi) .. "\0" .. lc .. "\0" .. oc
end

-- records: array of { poi, city, state, country, lat, lon, time }.
-- Returns out (array of { city, state, country }, same order/length) and
-- stats { groups, conflicts }.
function place_reconcile.reconcile(records, radius_km)
  local groups, order = {}, {}
  for i, r in ipairs(records) do
    local key = place_reconcile.group_key(r.poi, r.lat, r.lon, radius_km)
    local g = groups[key]
    if not g then g = {}; groups[key] = g; order[#order + 1] = key end
    g[#g + 1] = i
  end

  local winners = {}
  local conflicts = 0
  for _, key in ipairs(order) do
    -- Photos of the group, ordered by capture time (missing time last) so ties
    -- resolve to the earliest.
    local sorted = {}
    for _, i in ipairs(groups[key]) do sorted[#sorted + 1] = i end
    table.sort(sorted, function(a, b)
      local ta, tb = records[a].time, records[b].time
      if ta == tb then return a < b end
      if ta == nil then return false end
      if tb == nil then return true end
      return ta < tb
    end)

    local win = {}
    local group_conflict = false
    for _, field in ipairs(FIELDS) do
      local counts, firstpos, distinct = {}, {}, 0
      for pos, i in ipairs(sorted) do
        local v = records[i][field]
        if present(v) then
          if counts[v] == nil then distinct = distinct + 1; firstpos[v] = pos end
          counts[v] = (counts[v] or 0) + 1
        end
      end
      if distinct >= 2 then group_conflict = true end
      local best, bestcount, bestpos
      for v, c in pairs(counts) do
        if best == nil or c > bestcount
           or (c == bestcount and firstpos[v] < bestpos) then
          best, bestcount, bestpos = v, c, firstpos[v]
        end
      end
      win[field] = best  -- nil when the field is empty across the whole group
    end
    if group_conflict then conflicts = conflicts + 1 end
    winners[key] = win
  end

  local out = {}
  for i, r in ipairs(records) do
    local w = winners[place_reconcile.group_key(r.poi, r.lat, r.lon, radius_km)]
    out[i] = { city = w.city, state = w.state, country = w.country }
  end
  return out, { groups = #order, conflicts = conflicts }
end

return place_reconcile
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted spec/place_reconcile_spec.lua` then `busted`
Expected: all green; full suite = prior count + these tests.

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/place_reconcile.lua spec/place_reconcile_spec.lua
git commit -m "feat: place_reconcile — group by POI+cell, majority vote, time tie-break"
```

---

### Task 2: CleanupDialog (radius + launch)

**Files:**
- Create: `PhoneGeotagger.lrplugin/CleanupDialog.lua`

**Interfaces:**
- Produces: `CleanupDialog.run(args)` with `args = { photo_count, prefs }` → `{ radius_km }` or nil. Remembers `prefs.cleanup_radius_km`. Manual verification; `luac -p` + suite unchanged.

- [ ] **Step 1: Create CleanupDialog.lua**

```lua
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local CleanupDialog = {}

function CleanupDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("CleanupDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.radius_km = prefs.cleanup_radius_km or 2

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format("%d photo(s) selected.", args.photo_count),
      },
      f:static_text {
        title = "Reconciles City / State / Country for photos at the same place "
          .. "(same POI within the cluster radius) by majority vote, so a place "
          .. "no longer splits into multiple collections.",
        fill_horizontal = 1, width_in_chars = 44, height_in_lines = 3,
      },
      f:row {
        f:static_text { title = "Cluster radius (km):" },
        f:edit_field { value = bind "radius_km", width_in_chars = 6 },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Clean Up Place Names",
      contents = contents,
      actionVerb = "Clean Up Places",
    }
    if action ~= "ok" then return end
    local radius = tonumber(props.radius_km)
    if not radius or radius <= 0 then radius = 2 end
    prefs.cleanup_radius_km = radius
    result = { radius_km = radius }
  end)

  return result
end

return CleanupDialog
```

- [ ] **Step 2: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/CleanupDialog.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 3: Commit**

```bash
git add PhoneGeotagger.lrplugin/CleanupDialog.lua
git commit -m "feat: CleanupDialog — cluster radius + launch"
```

---

### Task 3: CleanupMenuItem + menu registration

**Files:**
- Create: `PhoneGeotagger.lrplugin/CleanupMenuItem.lua`
- Modify: `PhoneGeotagger.lrplugin/Info.lua`

**Interfaces:**
- Consumes: `place_reconcile.reconcile`, `CleanupDialog.run{photo_count, prefs}`; Lightroom SDK (`getTargetPhoto(s)`, `batchGetFormattedMetadata`, `batchGetRawMetadata`, `withWriteAccessDo`, `setRawMetadata`, `LrTasks.pcall`, `LrPrefs`).
- Produces: the offline cleanup command. Manual verification; `luac -p` + suite.

- [ ] **Step 1: Create CleanupMenuItem.lua**

```lua
local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPrefs = import "LrPrefs"

local place_reconcile = require "place_reconcile"
local CleanupDialog = require "CleanupDialog"

LrTasks.startAsyncTask(function()
  local ok, err = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    if catalog:getTargetPhoto() == nil then
      LrDialogs.message("Clean Up Place Names",
        "Select the photos to clean up in the Library grid first.", "info")
      return
    end
    local photos = catalog:getTargetPhotos()

    local prefs = LrPrefs.prefsForPlugin()
    local settings = CleanupDialog.run { photo_count = #photos, prefs = prefs }
    if not settings then return end

    local text = catalog:batchGetFormattedMetadata(photos,
      { "location", "city", "stateProvince", "country" })
    local raw = catalog:batchGetRawMetadata(photos,
      { "gps", "dateTimeOriginalISO8601" })

    -- Build reconcile records; skip photos without GPS.
    local records = {}
    local rec_photo = {}
    local skipped_no_gps = 0
    for _, photo in ipairs(photos) do
      local m = text[photo] or {}
      local rm = raw[photo] or {}
      local gps = rm.gps
      if gps and gps.latitude and gps.longitude then
        records[#records + 1] = {
          poi = m.location, city = m.city, state = m.stateProvince,
          country = m.country, lat = gps.latitude, lon = gps.longitude,
          time = rm.dateTimeOriginalISO8601,
        }
        rec_photo[#records] = photo
      else
        skipped_no_gps = skipped_no_gps + 1
      end
    end

    local resolved, stats = place_reconcile.reconcile(records, settings.radius_km)

    -- Collect the fields that actually change.
    local changes = {}
    for i, r in ipairs(records) do
      local w = resolved[i]
      local ch, any = {}, false
      if (w.city or "") ~= (r.city or "") then ch.city = w.city; any = true end
      if (w.state or "") ~= (r.state or "") then ch.state = w.state; any = true end
      if (w.country or "") ~= (r.country or "") then ch.country = w.country; any = true end
      if any then ch.photo = rec_photo[i]; changes[#changes + 1] = ch end
    end

    if #changes > 0 then
      catalog:withWriteAccessDo("Clean up place names", function()
        for _, ch in ipairs(changes) do
          if ch.city ~= nil then ch.photo:setRawMetadata("city", ch.city) end
          if ch.state ~= nil then ch.photo:setRawMetadata("stateProvince", ch.state) end
          if ch.country ~= nil then ch.photo:setRawMetadata("country", ch.country) end
        end
      end)
    end

    local msg = string.format(
      "Reconciled %d photo(s) across %d place(s).\n%d place(s) had conflicting values.",
      #changes, stats.groups, stats.conflicts)
    if skipped_no_gps > 0 then
      msg = msg .. string.format("\n%d photo(s) skipped (no GPS).", skipped_no_gps)
    end
    LrDialogs.message("Clean Up Place Names", msg, "info")
  end)
  if not ok then
    LrDialogs.message("Clean Up Place Names",
      "The command failed: " .. tostring(err), "critical")
  end
end)
```

- [ ] **Step 2: Register the menu item in Info.lua**

In `PhoneGeotagger.lrplugin/Info.lua`, add a fifth entry to `LrLibraryMenuItems` after the "Create Location Collections..." entry (keep all existing entries and the `LrPluginInfoProvider`/`VERSION` keys):

```lua
    {
      title = "Clean Up Place Names",
      file = "CleanupMenuItem.lua",
    },
```

- [ ] **Step 3: Syntax-check and guard against regressions**

Run:
```bash
luac -p PhoneGeotagger.lrplugin/CleanupMenuItem.lua PhoneGeotagger.lrplugin/Info.lua
busted
```
Expected: `luac` clean; `busted` unchanged.

- [ ] **Step 4: Manual test in Lightroom** (deferred to owner; note in report)

Select photos including the split place → **Clean Up Place Names** → set radius (default 2) → Clean Up Places → summary reports reconciled/groups/conflicts; the minority `country` values are rewritten to the majority, blanks filled, POI and GPS unchanged; re-running **Create Location Collections** now yields one `Hella, Iceland`.

- [ ] **Step 5: Commit**

```bash
git add PhoneGeotagger.lrplugin/CleanupMenuItem.lua PhoneGeotagger.lrplugin/Info.lua
git commit -m "feat: Clean Up Place Names menu command (offline IPTC reconciliation)"
```

---

## Self-Review

**Spec coverage:** dialog+radius (Task 2), grouping by POI+cell (Task 1 `group_key`), majority vote + earliest-time tie-break (Task 1 `reconcile`), write only changed fields + summary with groups/conflicts/skipped (Task 3), core unit-tested + shell manual (all tasks), Info.lua entry (Task 3). Covered.

**Type consistency:** `reconcile(records, radius_km)` → `out, stats` used exactly so in Task 3; record fields `{poi,city,state,country,lat,lon,time}` built in Task 3 match Task 1's expectations; write keys `city`/`stateProvince`/`country`, read `stateProvince` — consistent with the global constraint.

**Placeholder scan:** none — every step has complete code.
