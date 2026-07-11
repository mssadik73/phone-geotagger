# Place Name Cleanup — Design

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Adds:** an offline "Clean Up Place Names" command to Phone Geotagger

## Motivation

Geotagging resolves each photo's place through a ladder (visit placeId → nearby
POI → reverse geocode), and the tiers don't always agree: two photos at the
same place can end up with different administrative values. Observed in an
Iceland set — the town **Hella** produced two collections, `Hella, Iceland`
(12 photos) and `Hella, Rangárþing ytra` (2 photos), because a **municipality**
("Rangárþing ytra") leaked into the `country` field of two photos. The same
place split into two collections.

This adds a **separate, offline cleanup pass** that reconciles the place data
already written to IPTC: photos at the same place are grouped and their
City/State/Country are normalized to one agreed value, so a place yields one
collection. It does **not** change how geotagging resolves places (that is a
deliberate out-of-scope choice), so the pass is re-run after geotagging.

## Scope decisions (agreed)

- **Cleanup pass**, not a resolve-time fix. Re-run after geotagging.
- **Grouping:** POI name **+** GPS proximity (a configurable cluster radius).
- **Winner:** per-field **majority vote**; **ties broken by earliest capture
  time**.
- **One dialog** that both sets the radius and launches the pass — no extra
  confirmation step.

## Command & flow

New menu command **`Library → Plug-in Extras → Clean Up Place Names`**, run on
the **selected** photos (like Create Location Collections). Fully offline —
reads and writes IPTC only, no Google calls, no API key.

1. Guard: if nothing is selected, message and stop.
2. **Dialog** (`CleanupDialog`): shows "*N photo(s) selected.*", a **Cluster
   radius (km)** edit field (default **2**, remembered in `prefs.cleanup_radius_km`),
   and an action button **Clean Up Places** (plus Cancel). Clicking the action
   button is the go-ahead; there is no second confirmation.
3. Batch-read each photo's place + location + time (below), group, reconcile,
   and write the changed fields in one `withWriteAccessDo`.
4. Final summary message.

## Data read

Per selected photo, read:

- IPTC place via `batchGetFormattedMetadata`: `location` (POI), `city`,
  `stateProvince`, `country`.
- GPS via `batchGetRawMetadata`: `gps` (`{ latitude, longitude }`) — for
  proximity grouping.
- Capture time via `batchGetRawMetadata`: `dateTimeOriginalISO8601` (a
  string, sortable lexicographically) — for tie-breaking. Photos with no
  capture time sort **last** (they never win a tie over a timed photo).

A photo with no GPS is skipped (it can't be placed in a cluster) and counted
`skipped_no_gps`.

## Grouping into places

Grouping = **trimmed POI bucket + proximity clustering** (updated from an
earlier hard-grid idea, which a TDD test showed could split a 0.6 km-apart pair
across a cell boundary — defeating the merge):

- **POI bucket:** the photo's `location` trimmed; empty/absent POI is its own
  bucket (`""`), so no-POI (moving) photos are clustered by proximity alone and
  still get their City/State/Country reconciled among themselves.
- **Proximity clustering:** within each POI bucket, **single-linkage cluster**
  by distance — two records join the same group when within the dialog's
  **cluster radius** (`place_reconcile.distance_km` ≤ `radius_km`). Distance is
  an equirectangular approximation (`cos(mean latitude)` for longitude;
  `KM_PER_DEG = 111`; no `atan2`), accurate at cluster scale. This has **no grid
  boundaries**, so nearby photos of one place always merge, while same-named
  places farther apart than the radius stay in separate groups. Clustering is
  pairwise within a bucket (buckets are small — one POI); the empty-POI bucket
  can be larger but is a one-time offline pass.

`place_reconcile.groups(records, radius_km)` returns an array `gid` (record
index → integer group id) and the group count.

## Reconciliation (per-field majority vote)

For each group, for each field independently (`city`, `state`, `country`):

1. Tally counts of each **non-empty** value across the group's photos.
2. The value with the **highest count** wins.
3. **Tie** (two+ values share the highest count): the winner is the tied value
   carried by the photo with the **earliest capture time** in the group. (Sort
   the group's photos by `dateTimeOriginalISO8601` ascending, missing-time
   last; scan for the first photo whose value for this field is one of the
   tied values; that value wins.)
4. If the field is empty for **every** photo in the group, the winner is empty
   (nothing to write).

Every photo in the group is assigned the winning `city`/`state`/`country`. POI
(`location`) is the grouping key and is **not** changed. GPS is not changed.

## Core module (unit-tested)

`place_reconcile.lua` — Lightroom-independent, injected data, busted-tested:

- `place_reconcile.cell(lat, lon, radius_km)` → `lat_cell, lon_cell` integers
  (grid indices; `KM_PER_DEG = 111`).
- `place_reconcile.group_key(poi, lat, lon, radius_km)` → the string key.
- `place_reconcile.reconcile(records, radius_km)` where each record is
  `{ poi, city, state, country, lat, lon, time }` (`time` a sortable string or
  nil) → returns, for each input record (by index), the resolved
  `{ city, state, country }` for its group. Pure function: same inputs →
  same outputs. Encapsulates grouping, majority vote, and the earliest-time
  tie-break.

The Lightroom shell (`CleanupMenuItem`) reads metadata, calls
`place_reconcile.reconcile`, and writes back only the fields that changed.

## Write & summary

In one `withWriteAccessDo`, for each photo whose resolved value differs from its
current value, `setRawMetadata` the changed field(s) (`city`, `stateProvince`,
`country`). Count:

- `changed_photos` — photos with ≥1 field rewritten.
- `groups` — number of place groups.
- `conflicts` — groups where a field had 2+ distinct non-empty values (i.e., a
  real disagreement was resolved).
- `skipped_no_gps` — photos skipped for lack of GPS.

Summary message:

> Reconciled `changed_photos` photo(s) across `groups` place(s).
> `conflicts` place(s) had conflicting values.
> [`skipped_no_gps` photo(s) skipped (no GPS).]  ← only when > 0

## Components

### New (core, unit-tested)
- `place_reconcile.lua` — grouping, majority vote, earliest-time tie-break.

### New (Lightroom shell, manual verification)
- `CleanupDialog.lua` — the radius + launch dialog; returns
  `{ radius_km }` or nil.
- `CleanupMenuItem.lua` — read IPTC/GPS/time, reconcile, write, summarize.
- `Info.lua` — add the `Clean Up Place Names` entry to `LrLibraryMenuItems`.

### Reused as-is
- `collection_name.lua` (unchanged; it just benefits from cleaner data),
  `plugin_paths` (none needed here), the metadata read/write patterns from
  `LocationCollectionsMenuItem`.

## Error handling

| Situation | Behavior |
|---|---|
| No photos selected | Message; stop |
| Photo without GPS | Skipped; counted `skipped_no_gps` |
| Photo without capture time | Included; sorts last for tie-breaks |
| A field empty across a whole group | Left empty (nothing written) |
| No field changes anywhere | Summary reports 0 changed |
| Cancel in the dialog | Nothing happens |

## Testing

- **Unit (busted):** `place_reconcile` —
  - `cell` grid math (radius → cell size; points within/across a cell).
  - `group_key` separates same-POI-far-apart and merges same-POI-close;
    empty-POI grouped by cell.
  - majority vote picks the plurality value per field;
  - the Iceland scenario: country Iceland ×12 vs Rangárþing ytra ×2 →
    Iceland for all 14;
  - **tie broken by earliest capture time** (2 vs 2, earliest wins);
  - blanks filled from the group winner; all-empty field stays empty;
  - POI and GPS untouched.
- **Manual (Lightroom, owner):** run on a selection that has the split; verify
  the minority values are rewritten to the majority, blanks fill, POI/GPS
  unchanged, the summary counts are right, and re-running Create Location
  Collections now yields one `Hella, Iceland`.

## Out of scope (YAGNI)

- Fixing consistency at geotag/resolve time (deliberately deferred; re-run
  cleanup after geotagging).
- Reconciling the POI (`location`) itself — POI is the grouping key.
- Merging same-named places in different regions (kept separate by design).
- True distance-based clustering (a grid cell is used; radius is configurable).
- Undo beyond Lightroom's own edit history / re-geotag.
