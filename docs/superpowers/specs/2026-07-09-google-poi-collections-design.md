# Google POI Location Collections — Design

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Modifies:** the Location Collections feature of the Phone Geotagger plugin

## Motivation

Location collections should be named by recognizable **points of interest**
("Griffith Observatory", "Golden Gate Park"), not neighborhoods. OpenStreetMap
reverse geocoding returns whatever object sits at the exact GPS point (usually
a road or parking lot), so it can't provide real POI names. Google's Places API
can. This redesign drops OpenStreetMap entirely and sources all geocoding from
Google.

## Naming levels

The collection-name levels become **POI → City → State → Country** (POI
replaces the old neighborhood/sublocation). The format chooser's two popups list
POI / City / State / Country; **default primary = POI, secondary = City**, e.g.
`Griffith Observatory, Los Angeles`. When a photo has no POI, naming falls back
down the hierarchy (auto): City+State, then State+Country, then Country.

## Data source — Google only

All geocoding is Google, keyed by one API key. Per unique coordinate:

1. **Google Places API (New) `searchNearby`** — the nearest **notable** place
   within the radius, ranked by distance. Returns the POI name *and* its address
   components, so one call yields `{ poi, city, state, country }`.
2. **Google Geocoding API reverse** — a **fallback** used only when
   `searchNearby` returns no notable place, to still obtain
   `{ city, state, country }` for that coordinate.

So most coordinates cost one Places call; only POI-less coordinates cost a
second (Geocoding) call. OpenStreetMap/Nominatim is removed.

### Google Places `searchNearby` request
- `POST https://places.googleapis.com/v1/places:searchNearby`
- Headers: `Content-Type: application/json`, `X-Goog-Api-Key: <key>`,
  `X-Goog-FieldMask: places.displayName,places.addressComponents`
- Body: `includedTypes` = a **notable-types** list (kept as one constant in
  `google_geo.lua` so it is the single place to adjust if Google rejects a
  type): `tourist_attraction, park, national_park, museum, art_gallery,
  historical_landmark, monument, cultural_landmark, church, mosque, synagogue,
  hindu_temple, amusement_park, zoo, aquarium, stadium, plaza, garden`;
  `maxResultCount: 1`; `rankPreference: "DISTANCE"`;
  `locationRestriction.circle = { center:{latitude,longitude}, radius: 200 }`.
- Parse: `places[1].displayName.text` → poi; `places[1].addressComponents[]`
  (types `locality`/`postal_town` → city, `administrative_area_level_1` →
  state, `country` → country).

### Google Geocoding reverse (fallback)
- `GET https://maps.googleapis.com/maps/api/geocode/json?latlng=<lat>,<lon>&key=<key>`
- Parse `results[1].address_components[]` the same way (locality → city,
  administrative_area_level_1 → state, country → country).

Radius is a fixed **200 m**. Both APIs (Places API New + Geocoding API) must be
enabled on the key.

## API key — Plug-in Manager config screen

A new `PluginInfoProvider.lua` adds a **"Google API key"** field to the plugin's
section in **File → Plug-in Manager** (bound to `prefs.google_api_key`,
persisted, set once). `Info.lua` registers it via `LrPluginInfoProvider`.

Because Google is now the only source, the key is **required**. If it is empty,
the Create Location Collections command shows "Set your Google API key in the
Plug-in Manager (File → Plug-in Manager → Phone Geotagger) first." and stops.
The per-run dialog **drops the old "Geocoder endpoint" field** (Nominatim-only);
it keeps the collection-set name and the POI/City/State/Country format popups.

## Cache (required)

`geo_cache` bumps its file to `geocode-v3.json` (the place shape changed to
`{ poi, city, state, country }`). Every unique coordinate is resolved via Google
exactly once and reused across runs and photos, keeping billable calls minimal.

## Components

### Core (Lightroom-independent, unit-tested)
- **`google_geo.lua`** (new): injected HTTP (`http_post(url, body, headers)`,
  `http_get(url, headers)`).
  - `google_geo.nearest_poi(http_post, key, lat, lon, radius)` → `{ poi, city,
    state, country }` (poi may be nil if the response has an unnamed place) or
    `nil, error`.
  - `google_geo.reverse(http_get, key, lat, lon)` → `{ city, state, country }`
    or `nil, error`.
  - Shared `address_components` parsers for both Places and Geocoding shapes.
  - Holds the notable-`includedTypes` constant.
- **`collection_name.lua`** (changed): levels become
  `poi < city < state < country` (`ORDER`/`RANK` updated; `of`/`auto`/
  `format_error` logic unchanged). Tests updated to poi.
- **`geo_cache.lua`** (changed): `geocode_cache_path` → `geocode-v3.json` (in
  `plugin_paths`); cache stores `{ poi, city, state, country }`. Save/load
  logic unchanged.

### Lightroom shell (manual verification)
- **`PluginInfoProvider.lua`** (new): the Plug-in Manager config section with
  the Google API key field; `Info.lua` gains `LrPluginInfoProvider = "PluginInfoProvider.lua"`.
- **`LocationDialog.lua`** (changed): drop the endpoint field; level popups
  become POI/City/State/Country (default POI/City); still returns
  `{ set_name, primary, secondary }` (no endpoint).
- **`LocationCollectionsMenuItem.lua`** (changed): read `prefs.google_api_key`;
  if empty, show the set-key message and stop. Per coordinate (cache-first):
  `google_geo.nearest_poi`; if it yields no poi *and* no city, or is skipped,
  `google_geo.reverse` for city/state/country; merge → cache. Everything else
  (streaming flushes, regular-collection add, progress, pcall, cancel) is
  unchanged. `http_post`/`http_get` wrap `LrHttp.post`/`LrHttp.get`.

### Removed
- `geocode_client.lua` and `spec/geocode_client_spec.lua` (Nominatim).
- `place_extract.lua` and `spec/place_extract_spec.lua` (Nominatim parser).

## Error handling

| Situation | Behavior |
|---|---|
| No API key | Command shows the "set your key in Plug-in Manager" message and stops |
| Places returns no notable place | Fallback to Geocoding reverse for city/state/country; poi = nil |
| Both return nothing / HTTP error | Coordinate counted unresolved; not cached (retry next run) |
| Google error body (e.g. `error` / `status != OK`) | Treated as failure → unresolved, not cached |
| Photo without GPS | Skipped, counted |
| Cancel mid-run | Stops after current flush; resolved-so-far added + cache saved |
| Re-run | Cache hits, no new calls; adds photos to existing collections (no dupes) |

## Testing

- **Unit (busted):** `google_geo` — `nearest_poi` request shape (URL, headers,
  body JSON) and response parsing (POI + address components) via fake
  `http_post` + real-shaped Places fixture; `reverse` parsing via fake
  `http_get` + Geocoding fixture; no-result, error-body, and missing-field
  cases. `collection_name` — poi/city/state/country levels and validation.
  `geo_cache` — unchanged (v3 path is Lightroom-shell, in `plugin_paths`).
- **Manual (Lightroom, owner):** set the key in Plug-in Manager; run collections
  → collections named by POI ("Griffith Observatory, Los Angeles") with
  City/State/Country fallback; the notable-types list is accepted by Google
  (no 400); no-key path shows the prompt; cache (`geocode-v3.json`) written;
  re-run fast; cancel-safe.

## Out of scope (YAGNI)

- Keeping OpenStreetMap as an alternative backend (removed).
- Configurable radius or POI-type list in the UI (fixed constant; the list
  lives in one module constant).
- Backfilling POI into pre-existing cache entries (the v3 filename bump makes
  the cache rebuild fresh under the new shape).
- Google Places "prominence" ranking (nearest notable only).
