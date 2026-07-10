# placeId-Based Google POI Resolution — Design

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Modifies:** the geotag, correction, and collection features of Phone Geotagger

## Motivation

Google Timeline visits carry a `placeId` that the parser currently discards.
Resolving the place from that `placeId` (Google Place Details) gives the exact
place you were at — far better than reverse-geocoding an interpolated GPS point.
This redesign resolves the place **at geotag time** (from the visit's placeId,
or a Google reverse-geocode when moving), writes it into the photo's IPTC
fields, and makes collection creation a pure **offline** pass. Correction is
likewise Google-based: the user searches Google for a POI instead of picking a
GPS point on a map.

All geocoding is Google, via one API key set in the Plug-in Manager. The key is
**required** for geotagging and correction (both resolve places).

## Place model

A resolved place is `{ poi, city, state, country }` (any field may be nil). It
is written to the photo's IPTC fields and read back for collections:

| Place field | Write (`setRawMetadata`) | Read (`getFormattedMetadata`) |
|---|---|---|
| poi | `location` (Sublocation) | `location` |
| city | `city` | `city` |
| state | `stateProvince` | `state` |
| country | `country` | `country` |

Collection naming levels stay **poi < city < state < country**
(`collection_name`, already built).

## 1. Geotag: resolve place + write IPTC

The geotag command (`GeotagMenuItem`) gains place resolution:

1. Require `prefs.google_api_key`; if empty, show "Set your Google API key in
   the Plug-in Manager (File → Plug-in Manager → Phone Geotagger) first." and
   stop.
2. For each photo: compute UTC time (existing `time_resolver` + dialog tz).
3. **Match, visit-first:** `visit_matcher.match(visits, utc)` — if the time is
   inside a visit interval, use that visit (`place_id`, `lat`, `lon`); GPS snaps
   to the visit's coordinate. Otherwise `matcher.match(points, utc, gap)` gives
   an interpolated coordinate (rounded via `coord_round` at the dialog
   precision). No match at all → photo left untagged (as today).
4. **Resolve the place:**
   - Visit: `google_geo.place_details(http_get, key, place_id)` →
     `{ poi, city, state, country }`.
   - Movement: `google_geo.reverse(http_get, key, lat, lon)` →
     `{ city, state, country }` (no poi).
   - Both go through the **resolution cache** (below) so each place/coordinate is
     resolved once.
5. **Write** GPS and the IPTC place fields in one `withWriteAccessDo`, honoring
   the existing "overwrite existing GPS" behavior (extended to also govern the
   location fields).
6. Summary reports tagged / skipped / no-match plus a place-resolution count.

## 2. Timeline visits (parser + history cache)

- **`timeline_parser`** currently flattens visits to coordinate points and drops
  the `placeId`. It will additionally return a **visits** list — each visit
  `{ start_t, end_t, place_id, lat, lon }` from a `semanticSegments[].visit`
  (`topCandidate.placeId`, `topCandidate.placeLocation.latLng`, segment
  `startTime`/`endTime`). It keeps returning the movement track points (for
  interpolation). New return shape: `{ points = {...}, visits = {...} }`.
- **`history_cache`** accumulates both points and visits so old photos can still
  be geotagged from past exports (now with their placeIds). Its file format
  becomes JSON `{ points = [...], visits = [...] }` under a new filename
  (`history-v2.json`); the old `history.csv` is abandoned (re-import to get
  visits/placeIds). `merge`/`coverage` extend to visits.
- **`visit_matcher`** (new, pure): `match(visits, utc_seconds)` → the visit whose
  `[start_t, end_t]` contains `utc_seconds` (nearest start on overlap), or nil.

## 3. Google client (`google_geo`)

`google_geo` (already has `reverse` + the shared address parser) gains:

- `place_details(http_get, key, place_id)` — Places API (New)
  `GET https://places.googleapis.com/v1/places/<place_id>` with headers
  `X-Goog-Api-Key`, `X-Goog-FieldMask: displayName,addressComponents` → parses
  `displayName.text` (poi) + `addressComponents` (`longText`) → `{ poi, city,
  state, country }` or `nil, error`.
- `text_search(http_post, key, query, bias_lat, bias_lon)` — Places API (New)
  `POST https://places.googleapis.com/v1/places:searchText`, field mask
  `places.id,places.displayName,places.location,places.addressComponents`,
  body `{ textQuery = query, maxResultCount = 8, locationBias.circle = {
  center:{latitude=bias_lat,longitude=bias_lon}, radius: 50000 } }` (bias
  omitted when lat/lon are nil) → a list of `{ place_id, poi, city, state,
  country, lat, lon }` (from each place's `id`, `displayName`, `location`,
  `addressComponents`) or `nil, error`.
- `reverse(http_get, key, lat, lon)` — kept unchanged.
- The unused `nearest_poi` (searchNearby) is **removed**.

`http_get(url, headers)` (headers optional) and `http_post(url, body, headers)`
are injected; the shell wraps `LrHttp.get`/`LrHttp.post`.

## 4. Resolution cache

The repurposed `geo_cache` stores resolved places keyed by string:
`"pid:" .. place_id` for placeId lookups and `geo_cache.key(lat, lon)` for
reverse lookups (mixed keys in one JSON file, new filename
`resolve-v1.json`). Each place/coordinate is resolved via Google once and reused
across photos and runs. Failed lookups are not cached (retry next run).

## 5. Correction: pick a Google POI (`CorrectDialog`)

"Correct Geotag of Selection" no longer uses a map/clipboard; it searches
Google:

1. The dialog shows the current tag, a **"Search for a place"** text field, and a
   **Search** button.
2. Search calls `google_geo.text_search(http_post, key, query, cur_lat, cur_lon)`
   (biased to the selection's current coordinate) and fills a popup with the
   result place names.
3. On **Apply**, the picked result's coordinate is written as GPS and its
   `{ poi, city, state, country }` into the IPTC fields of every selected photo
   (one `withWriteAccessDo`).

Requires the key (same message if missing). "Find Photos With This Geotag"
(select the group sharing a tag) is unchanged.

## 6. Collections: offline

`LocationCollectionsMenuItem` drops all geocoding, the key, and the cache. For
each selected photo it reads IPTC via `batchGetFormattedMetadata`
(`location`, `city`, `state`, `country`), builds `place = { poi=location, city,
state, country }`, names via `collection_name.of(place, fmt)`, and streams into
regular collections (existing flush/progress/cancel). `LocationDialog` keeps the
set-name and POI/City/State/Country format popups; the endpoint field is gone.
Photos geotagged before this feature have no IPTC place and are counted
"unresolved" until re-geotagged (README note).

## 7. Components

### New (core, unit-tested)
- `visit_matcher.lua` — interval containment.

### New (Lightroom shell)
- `PluginInfoProvider.lua` — Google API key field in the Plug-in Manager;
  `Info.lua` gains `LrPluginInfoProvider`.

### Changed
- `timeline_parser.lua` — return `{ points, visits }` (+ tests, fixtures with a
  visit `placeId`).
- `history_cache.lua` — store points + visits as JSON `history-v2.json`
  (+ tests).
- `google_geo.lua` — add `place_details` + `text_search`, remove `nearest_poi`
  (+ tests).
- `geo_cache.lua` — placeId+coord string keys, `resolve-v1.json`
  (`plugin_paths`).
- `GeotagMenuItem.lua` — visit-first match, resolve place, write GPS + IPTC, key
  check.
- `GeotagDialog.lua` — no new fields (uses existing precision/overwrite); reads
  the cache's new `{points, visits}` shape for the coverage line.
- `CorrectDialog.lua` — Google POI search instead of map/clipboard.
- `CorrectGeotagMenuItem.lua` — write the picked place's GPS + IPTC; key check.
- `LocationCollectionsMenuItem.lua` — offline IPTC read.
- `LocationDialog.lua` — POI levels, drop endpoint.
- `plugin_paths.lua` — `history-v2.json`, `resolve-v1.json` paths.

### Removed (+ specs)
- `geocode_client.lua`, `place_extract.lua` (Nominatim).
- `mappicker.html`, `leaflet.js`, `leaflet.css` (map picker).
- `clipboard.lua`, `coord_parse.lua`, `LrExec.lua` (map/clipboard round-trip;
  verify `LrExec` has no other consumer).
- `candidate_finder.lua` (history-candidate suggestions, replaced by search).

### Reused as-is
- `collection_name.lua` (POI levels), `coord_round.lua`, `matcher.lua`,
  `geo_group.lua` (used by "Find Photos With This Geotag"), `iso8601.lua`,
  `time_resolver.lua`, `tz_offsets.lua`, `dkjson.lua`.

## Error handling

| Situation | Behavior |
|---|---|
| No API key (geotag / correct) | Message pointing to Plug-in Manager; stop |
| Photo with no Timeline match | Left untagged; counted no-match |
| Visit placeId resolve fails | Counted; photo gets GPS but no place (retry next run) |
| Reverse fails (movement) | GPS written, no place; not cached |
| Text search returns nothing | Dialog says "no places found"; no write |
| Collections: photo has no IPTC place | Counted unresolved |
| Cancel mid-run | Consistent partial result; cache saved (geotag) |

## Testing

- **Unit (busted):** `timeline_parser` (visits with placeId + interval, both
  formats), `history_cache` (points + visits JSON round-trip, merge),
  `visit_matcher` (inside/outside/boundary/overlap), `google_geo`
  (`place_details` + `text_search` request shape and parsing, `reverse`
  unchanged). `collection_name`/`coord_round`/`matcher` unchanged.
- **Manual (Lightroom, owner):** set the key; geotag → photos get GPS +
  Sublocation/City/State/Country from the visit placeId (POI names), movement
  photos get City/State/Country; correction search → pick a Google place →
  written to the selection; collections built offline from the IPTC; the notable
  types / field masks are accepted by Google (no 4xx).

## Out of scope (YAGNI)
- Keeping OpenStreetMap or the Leaflet map picker.
- Per-photo place override beyond the group correction.
- Backfilling IPTC into photos geotagged before this feature (re-geotag).
