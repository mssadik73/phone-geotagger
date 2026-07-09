# Location Collections — Design (v3 feature)

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Builds on:** the shipped Phone Geotagger plugin (v1 geotagging, v2 correction)

## Problem

After geotagging, photos carry GPS coordinates but no human-readable place
names, and Lightroom offers no way to browse them by location. The user wants
auto-updating Smart Collections named for real places (e.g. "Venice Beach"),
like the Collections panel in the reference screenshot.

## Key SDK constraint (why this works the way it does)

Lightroom's native Smart Collections **cannot** filter by GPS proximity to a
coordinate. Their only location-related rules are the text IPTC fields
(Country, State/Province, City, Location/Sublocation) and "GPS data
present/absent". Therefore a genuinely *smart* (auto-updating) collection for a
place is possible only if photos carry that place's **name** in a metadata
field. This feature reverse-geocodes GPS into those IPTC fields, then builds
Smart Collections keyed on them.

## User workflow — one command

**Library → Plug-in Extras → Create Location Collections...**

1. Select photos in the grid.
2. A dialog shows: the collection-set name (default **"Geo Locations"**), an
   **overwrite existing location metadata** checkbox, the configurable
   geocoder endpoint, and a live count ("142 photos, 18 unique locations to
   look up, ~20 s").
3. On run: a cancelable progress bar reverse-geocodes each *unique*
   coordinate (throttled + cached), writes the place fields into the photos in
   one catalog write block, then creates/refreshes the Smart Collections.
4. Summary: "18 locations resolved, 3 unresolved, 12 Smart Collections
   created/updated."

Scope: operates on **selected** photos. Photos that already have a City or
Sublocation are skipped unless "overwrite" is checked (mirrors the geotag
command's skip-then-overwrite behavior).

## What gets written and created

For each photo's GPS, OpenStreetMap (Nominatim) reverse-geocoding yields an
address. The plugin writes the standard IPTC fields via `setRawMetadata`:

- **country** ← address country
- **stateProvince** ← address state
- **city** ← address city / town / village / municipality (first present)
- **location** (IPTC Sublocation) ← neighborhood: neighbourhood → suburb →
  quarter → city_district → (fallback) city, first present

Then it creates a Smart Collection **set** named "Geo Locations" (configurable)
containing one Smart Collection per distinct **(sublocation, city)** pair,
each with a compound rule:

```
Sublocation = "<neighborhood>"  AND  City = "<city>"
```

The compound rule prevents identically-named neighborhoods in different cities
from merging. Each collection is named for its neighborhood (its sublocation).
Because the collections are keyed on the written fields, they **auto-update**
as future photos get geocoded. Creation is **idempotent**: an existing smart
collection of the same name in the set is reused (via
`createSmartCollection(..., canReturnExisting = true)`), not duplicated.

## Components

Core modules stay Lightroom-independent and unit-tested (busted); the shell
layer is verified manually in Lightroom.

### Core (new, unit-tested)
- **geocode_client.lua** — `reverse_url(endpoint, lat, lon)` builds the
  Nominatim reverse-geocode URL; `reverse(http_get, endpoint, lat, lon)` calls
  the injected `http_get(url, headers)` and returns the decoded address table
  or `nil, error`. Injected HTTP keeps it Lightroom-free and testable with
  fixture JSON.
- **place_extract.lua** — `extract(address)` takes a Nominatim `address`
  object and returns `{ country, state, city, sublocation }`, applying the
  fallback chains (neighborhood levels; city/town/village) and leaving fields
  `nil` when absent. Pure function; this is where geocoding messiness is tamed.
- **geo_cache.lua** — persistent map from a rounded-coordinate key to a
  resolved place `{country, state, city, sublocation}`. `key(lat, lon)`,
  `load(path)`, `get(cache, lat, lon)`, `put(cache, lat, lon, place)`,
  `save(path, cache)`. Rounds to 4 decimals (~11 m) so shared locations cost
  one lookup. Same file-cache discipline as the history cache (tmp+rename).
- **smartcoll_rules.lua** — `build(sublocation, city)` returns the Lightroom
  smart-collection search-description table (combine = "intersect"; two
  criteria on `location` and `city`, operator "==", the given values). Pure
  data; testable without Lightroom.

### Lightroom shell (new, manual verification)
- **LocationDialog.lua** — the run dialog: set-name field, overwrite checkbox,
  endpoint field, live counts; returns settings or nil on cancel.
- **LocationCollectionsMenuItem.lua** — the command: gather selected photos,
  dedupe unique coordinates (skip photos that already have city/sublocation
  unless overwrite), reverse-geocode each unique coordinate (throttled +
  cached, progress, cancelable) via `LrHttp.get`, write IPTC fields in one
  `withWriteAccessDo`, then create/refresh the smart-collection set and its
  members; summary dialog.
- **Info.lua** — one new `LrLibraryMenuItems` entry titled
  `Create Location Collections...`.

## Data flow

Selected photos → unique GPS coordinates (skip already-tagged unless
overwrite) → for each unique coord: `geo_cache.get` hit, else
`geocode_client.reverse` (throttled `LrHttp.get`) → `place_extract.extract` →
`geo_cache.put` → write country/state/city/location to every photo at that
coord (one write block) → for each distinct (sublocation, city):
`smartcoll_rules.build` → `catalog:createSmartCollection` under the set.

## Rate limits & endpoint

- OSM Nominatim public policy: ≤ 1 request/second, a valid identifying
  User-Agent, and no heavy systematic use. The plugin sends User-Agent
  `PhoneGeotagger/<version> (github.com/mssadik73/phone-geotagger)`, throttles
  **1.1 s between unique lookups**, and caches persistently so repeat runs and
  shared locations issue no new requests.
- The geocoder endpoint is a dialog/settings field (default
  `https://nominatim.openstreetmap.org/reverse`) so power users can point at
  their own Nominatim instance for large jobs.

## Error handling

| Situation | Behavior |
|---|---|
| Photo without GPS | Skipped; counted in summary |
| Photo already has city/sublocation, no overwrite | Skipped |
| Coordinate returns no usable address | Counted "unresolved"; photo left untagged; no collection |
| Network/endpoint failure mid-run | Locations resolved so far still get fields + collections; rest reported unresolved |
| Empty selection | `getTargetPhoto() == nil` guard → "select photos first" |
| Cancel during geocoding | Stops after the current lookup; writes + collections for what resolved |
| Smart collection already exists | Reused (canReturnExisting), not duplicated |

## Testing

- **Unit (busted):** `place_extract` (address fallbacks with real OSM JSON
  fixtures — urban, rural-no-neighborhood, missing-city, non-English),
  `geocode_client.reverse_url` + `reverse` (fixture JSON via fake http, error
  path), `geo_cache` (rounding key, dedup, round-trip save/load),
  `smartcoll_rules.build` (exact search-description shape).
- **Manual (Lightroom):** the command end-to-end — dialog, throttled
  geocoding with progress/cancel, IPTC fields written, smart-collection set +
  members created, auto-update behavior when a new photo is geocoded,
  idempotent re-run. Folded into the plugin's manual checklist.

## Out of scope (YAGNI)

- Configurable granularity UI (fixed at neighborhood→city fallback for v1;
  full country/state/city/neighborhood hierarchy of fields is written, so the
  user can build coarser smart collections by hand).
- Forward geocoding / place search (that lives in the v2 map picker).
- Bundling a local Nominatim server (endpoint is configurable instead).
- Reverse-geocoding photos with no GPS or writing GPS (this feature only reads
  GPS and writes place names).
- Collection sets beyond the single configurable parent set.
