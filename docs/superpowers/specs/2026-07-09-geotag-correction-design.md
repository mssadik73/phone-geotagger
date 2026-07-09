# Geotag Correction Flow — Design (v2 feature)

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Builds on:** the shipped Phone Geotagger plugin
(`docs/superpowers/specs/2026-07-09-phone-geotagger-design.md`)

## Problem

Google Timeline sometimes snaps a location to a *nearby but wrong* place
(e.g. a visit resolved to an adjacent venue). After the main geotagging run,
many photos can share the same slightly-wrong coordinate. The user needs to
find every photo carrying a bad tag and batch-correct them to the true spot.

## User workflow — two menu commands

Both appear under **Library → Plug-in Extras**, alongside the existing
"Geotag from Phone Timeline...".

### 1. Find Photos With This Geotag

1. Select one example photo that carries the bad tag.
2. Run the command. The plugin reads that photo's GPS, scans the whole
   catalog, and selects every photo whose GPS is within the **grouping
   tolerance** (default 25 m) in the Library grid.
3. A summary reports the count ("47 photos share this geotag within 25 m").
4. The user reviews the grid selection with Lightroom's own browsing and
   deselects any photos that don't belong.

This command only *selects*; it never modifies photos.

### 2. Correct Geotag of Selection…

Opens a modal dialog for the current selection:

```
Correct geotag — 43 photos selected ────────────────────
 Current tag: 23.81030, 90.41250   (from the first selected photo)

 Choose the corrected location:

 ( ) From Timeline history near this location:
       23.81100, 90.41000   (~180 m away)
       23.79001, 90.30000   (~410 m away)
       [ up to 10, nearest first; "none found nearby" if empty ]

 ( ) From map:   [ Open map picker ]   picked: (none yet)
                 [ Use location from map ]

              [ Cancel ]  [ Apply to 43 photos ]
```

On **Apply**, every selected photo gets the chosen coordinate written in a
single catalog write block. Summary: "43 photos re-tagged to
23.81100, 90.41000."

## Coordinate sources

There is **no manual typing** — the Lightroom SDK has no map/browser widget,
so coordinates come from one of two sources:

### From Timeline history (primary, one click)
The plugin searches the cached location history for recorded points within a
radius of the current (wrong) tag, nearest first, capped at 10. Because the
true location is nearby by premise, the raw GPS points recorded there are
usually the correct spot even when Google snapped the visit to the wrong
place, so this directly attacks the root cause. Each row shows the coordinate
and its distance from the current tag. (The cache stores flattened points, so
no visit/raw-signal type label is shown.)

### From map picker (always-works fallback)
No embedded widget exists, so the map lives in the user's browser and the
picked coordinate returns via the system clipboard (the plugin already shells
out for ADB; reading the clipboard is the same mechanism).

- **Open map picker** launches the bundled `mappicker.html` in the default
  browser, passing the current coordinate as a URL query parameter.
- The map (Leaflet + OpenStreetMap tiles + Nominatim search box, no API key)
  opens centered on the current coordinate with a **draggable marker already
  dropped on it**, and pre-copies that coordinate to the clipboard.
- Dragging the marker, clicking the map, or choosing a search result moves
  the marker and re-copies the new `lat, lon`, showing a "Copied ✓"
  confirmation on the page.
- **Use location from map** runs the platform clipboard-read command
  (`pbpaste` on macOS, `powershell -command Get-Clipboard` on Windows),
  validates the text through `coord_parse`, and fills the "picked:" display.
  Invalid clipboard content shows an inline "click the map first" message.

Leaflet's JS/CSS are bundled so the page's controls work offline; the tiles
and search require connectivity, which is expected when looking a place up.

## Components

Core modules stay Lightroom-independent and unit-tested (busted); the shell
layer is verified manually in Lightroom.

### Core (new, unit-tested)
- **geo_group.lua** — `haversine(lat1, lon1, lat2, lon2)` → meters;
  `filter_within(candidates, lat, lon, radius_m)` → items within the radius,
  each annotated with distance, sorted nearest first. Pure math.
- **coord_parse.lua** — `parse(text)` → `lat, lon` or `nil, error`. Accepts
  "lat, lon" and "lat lon", tolerates surrounding whitespace/junk, rejects
  out-of-range values (|lat| ≤ 90, |lon| ≤ 180).
- **candidate_finder.lua** — given the current coordinate, the history cache
  points, and options (radius, max), returns up to N nearby history
  candidates, deduped by rounded coordinate, annotated with distance, nearest
  first. Reuses the new `geo_group`.
- **clipboard.lua** — `read_command()` → platform clipboard-read command
  string; `read(exec)` → trimmed clipboard text via an injected `exec`
  (same injection pattern as `adb_client`). Command-building unit-tested
  with a fake exec.

### Lightroom shell (new, manual verification)
- **FindGeotagGroupMenuItem.lua** — command 1: reads the example photo's GPS,
  scans the catalog via `catalog:getAllPhotos()` + `batchGetRawMetadata`,
  applies `geo_group.filter_within`, and sets the grid selection via
  `catalog:setSelectedPhotos`. (GPS is not reliably searchable through
  `findPhotos`, so a batched metadata scan is the correct mechanism.)
- **CorrectGeotagMenuItem.lua** — command 2: gathers the selection, builds the
  candidate list, runs the dialog, and writes the chosen coordinate to all
  selected photos in one `catalog:withWriteAccessDo` block.
- **CorrectDialog.lua** — the dialog view/logic: radio between history
  candidates and the map source, the map-picker launch, the clipboard read,
  Apply enable/disable.
- **mappicker.html** — bundled self-contained Leaflet page with a draggable
  marker, search box, and auto-copy-to-clipboard. Reads the start coordinate
  from a URL query parameter.
- **Info.lua** — two new `LrLibraryMenuItems` entries.

## Data flow

Example photo GPS → `geo_group.filter_within` over the catalog's batched GPS
→ grid selection (command 1). Then: first selected photo's GPS →
`candidate_finder` over the cache (proximity to that coordinate) → user picks
a history candidate **or** the map-picked coordinate (clipboard →
`coord_parse`) → batched `setRawMetadata('gps', …)` in one write block
(command 2).

## Defaults

- Grouping tolerance: **25 m** (configurable in the correction dialog later if
  needed; fixed default for v1).
- History candidate radius: **500 m**, capped at **10** nearest.

## Error handling

| Situation | Behavior |
|---|---|
| Example photo has no GPS | "This photo has no geotag to match." |
| No photos within tolerance | Selects just the example photo; reports count 1 |
| Empty selection (command 2) | Existing "select photos first" message |
| No history candidates nearby | List shows "none found nearby"; map path still works |
| Clipboard has no valid coords | Inline "click the map first" message; Apply stays disabled |
| Neither source chosen | Apply disabled until a coordinate is picked |
| Grouping | Never writes; only selects |

## Testing

- **Unit (busted):** `geo_group` (haversine against known city-pair distances,
  radius filtering and sort order), `coord_parse` (valid forms, junk, range
  rejection), `candidate_finder` (sorting, dedup, cap, empty history),
  `clipboard.read_command` (per-platform strings).
- **Manual (Lightroom):** both commands end-to-end — grouping accuracy, grid
  selection, map picker launch + draggable marker + clipboard round-trip,
  batched write, summary. Folded into the plugin's manual checklist.

## Out of scope (YAGNI)

- Plotting history candidates as markers on the bundled map (list is enough).
- Editing the grouping tolerance mid-run via UI (fixed default for v1).
- Manual coordinate typing (deliberately removed — map picker only).
- A local map server / POST round-trip (clipboard hand-off avoids the
  server-runtime dependency the plugin intentionally lacks).
- Undo beyond Lightroom's native catalog undo.
