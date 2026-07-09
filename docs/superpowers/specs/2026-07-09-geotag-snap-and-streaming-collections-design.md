# Geotag Snapping + Streaming Location Collections — Design

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Modifies:** the shipped Phone Geotagger plugin

Two independent improvements.

---

## Improvement 1: Snap geotag coordinates

### Problem
The matcher interpolates a unique lat/lon for every photo, so a burst of photos
taken at one spot scatters across several meters on the map instead of showing
as a single pin.

### Fix
Round each matched coordinate to a chosen precision before writing, so
co-located photos get an identical value (one pin). This is a pipeline step;
the matcher stays a pure interpolator.

### Components
- **New core module `coord_round.lua`** (Lightroom-independent, unit-tested):
  - `coord_round.round(lat, lon, decimals)` → rounded `lat, lon`. Rounds each to
    `decimals` places via `math.floor(x * 10^decimals + 0.5) / 10^decimals`.
    Correct for positive and negative values.
- **`GeotagDialog.lua`**: add a **"Location precision"** popup with items
  `Exact` → 8, `~11 m (4 decimals)` → 4, `~110 m (3 decimals)` → 3. Bound to a
  new `prefs.precision`, default **4** (~11 m). "Exact" uses 8 decimals — below
  GPS precision, so effectively no rounding, while avoiding nil handling in the
  popup. The returned settings table gains `precision = <decimals>`.
- **`GeotagMenuItem.lua`**: after `matcher.match` returns `lat, lon`, apply
  `coord_round.round(lat, lon, settings.precision)` before `setRawMetadata`.

### Scope
Only the **Geotag from Phone Timeline** command. The correction command writes
one user-chosen coordinate to the whole selection, so it already yields one pin
and is unchanged.

---

## Improvement 2: Streaming regular Location Collections

### Change of model
Switch Location Collections from auto-updating **Smart Collections** to regular
**Collections** populated by iterating photos. This matches the requested
algorithm (iterate → resolve name → create-or-add), is naturally incremental
and low-memory, and scales to very large selections (5K+ images). Trade-off,
accepted: collections are a static snapshot — re-run to add newly geotagged
photos (re-running adds them to existing collections; adding a photo already in
a collection is a no-op).

No IPTC metadata is written in this command anymore.

### Collection naming (hierarchical, finest + parent context)
Each photo's place is reverse-geocoded to levels neighborhood / city / state /
country. The collection name is the **finest present level, plus the next
coarser present level for context**, comma-joined:

| Finest present | Name |
|---|---|
| neighborhood (+ city) | `Venice Beach, Los Angeles` |
| neighborhood (no city, + state) | `Venice Beach, California` |
| city (+ state) | `Los Angeles, California` |
| city (no state, + country) | `Los Angeles, United States` |
| state (+ country) | `California, United States` |
| country only | `United States` |
| nothing | unresolved (skip) |

Including the parent level in the name disambiguates same-named neighborhoods
in different cities for free.

### Components
- **`place_extract.lua`** (changed): `sublocation` becomes the **raw
  neighborhood** (neighbourhood → suburb → quarter → city_district), with **no
  city fallback**. Return shape stays `{ country, state, city, sublocation }`
  with `sublocation = nil` when there is no neighborhood. (Its one test that
  expected the city fallback is updated.)
- **New core module `collection_name.lua`** (Lightroom-independent,
  unit-tested):
  - `collection_name.of(place)` → the collection name string, or `nil` when no
    level is present. `place = { sublocation, city, state, country }`. Picks the
    finest present level as primary and the next coarser present level as
    context; returns `primary` or `primary .. ", " .. context`.
- **`LocationCollectionsMenuItem.lua`** (rewritten): the streaming loop
  (see below). Uses `geo_cache`, `geocode_client`, `place_extract`,
  `collection_name`, `plugin_paths`, `LocationDialog`. No longer uses
  `smartcoll_rules`, `batchGetFormattedMetadata`, or `setRawMetadata`.
- **`LocationDialog.lua`** (changed): remove the "overwrite existing location
  metadata" checkbox and its pref (no metadata to overwrite). Keep the set-name
  and geocoder-endpoint fields and the count line.
- **Removed:** `smartcoll_rules.lua` and `spec/smartcoll_rules_spec.lua`
  (no smart rules or name disambiguation needed).

### Streaming loop
1. Empty-selection guard (`getTargetPhoto() == nil`); gather target photos.
2. Show the dialog (set name, endpoint); return on cancel. The pre-dialog count
   is the number of selected photos (upper bound).
3. Load the geo cache. Create/get the parent collection **set** (the configured
   name) in a short write block.
4. Iterate photos with a cancelable progress scope. For each photo:
   - Read GPS via `photo:getRawMetadata("gps")` (one photo at a time — lowest
     memory). Skip photos without GPS.
   - Resolve the place: `geo_cache.get`, else `geocode_client.reverse`
     (throttled `LrTasks.sleep(1.1)` on a real network lookup only; failed
     lookups are **not** cached so they retry) → `place_extract.extract` →
     `geo_cache.put`. Resolution happens **outside** any write block.
   - `name = collection_name.of(place)`; if `nil`, count unresolved and skip.
   - Buffer the photo under `name` (`pending[name][#+1] = photo`).
   - **Every 500 processed photos, flush** (see below).
5. Final flush. Save the cache. Summary dialog: added / unresolved / no-GPS
   counts and the collection count.

**Flush** (bounded write, bounded memory): open one `withWriteAccessDo`; for
each buffered name, get-or-create its collection via
`catalog:createCollection(name, set, true)` (cache the handle in a
`name → collection` map so later flushes reuse it), then `collection:addPhotos`
the buffered photos for that name; clear the buffer; `geo_cache.save` after the
gate. Write gates stay short (never held during the throttled geocoding), and
resident memory is bounded to ~500 photo refs + the `name → collection` map +
the location cache (all bounded by distinct places, not image count).

### Behavior / edge cases
| Situation | Behavior |
|---|---|
| Empty selection | "select photos first" message |
| Photo without GPS | Skipped; counted |
| Coordinate resolves to no place | Counted unresolved; skipped |
| Network fails mid-run | Places resolved so far are added and cached; rest unresolved |
| Cancel mid-run | Stops after the current flush; everything so far added + cache saved |
| Re-run | Adds photos to existing collections; duplicates are no-ops |
| Two cities share a neighborhood name | Distinguished by the parent level in the name |

### README
Update the Location Collections section: regular (static, re-runnable)
collections named `Neighborhood, City` (or the coarser fallback), not
auto-updating Smart Collections; re-run to fold in newly geotagged photos.

---

## Testing
- **Unit (busted):** `coord_round.round` (positive/negative/precision cases),
  `collection_name.of` (each cascade row incl. gaps and the empty case),
  `place_extract.extract` (updated: `sublocation` is raw neighborhood, nil when
  absent). Net test delta: +coord_round, +collection_name, −smartcoll_rules,
  place_extract adjusted.
- **Manual (Lightroom, owner):** geotag a burst at one spot at ~11 m precision →
  a single pin; the precision dropdown changes clustering. Location Collections
  on a large selection → regular collections named `Neighborhood, City` appear
  and fill incrementally; memory stays flat; re-run adds without duplicating;
  cancel leaves a consistent partial result.

## Out of scope
- Configurable chunk/flush size (fixed internal constant).
- Any change to the correction command or the core matcher algorithm.
- Restoring smart-collection / auto-update behavior.
