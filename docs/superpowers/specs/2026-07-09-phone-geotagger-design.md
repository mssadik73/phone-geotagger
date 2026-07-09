# Phone Geotagger — Lightroom Classic Plugin Design

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan

## Overview

An open-source (MIT) Adobe Lightroom Classic plugin that geotags photos using
Google Timeline location history exported from an Android phone. For each
selected photo, the plugin converts the capture time to UTC, looks up where the
phone was at that moment in the accumulated location history, and writes GPS
coordinates into the Lightroom catalog.

Distribution target: GitHub, installable as a single `.lrplugin` folder. Only
external dependency is `adb` (optional — a file picker fallback exists).

## User workflow

1. **On the phone (occasionally):** Settings → Location → Timeline → Export
   Timeline data → save JSON (e.g., to Downloads). This step requires a human
   tap; it cannot be automated over ADB.
2. **In Lightroom:** select photos → Library → Plug-in Extras → *Geotag from
   Phone Timeline…*
3. **In the dialog:** optionally pull a fresh export over ADB (or browse to a
   local copy), confirm camera-time settings, click *Geotag*.
4. **Result:** progress bar, then a summary: tagged / skipped (had GPS) /
   no match counts, plus first and last matched coordinates as a sanity check.

## Key decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Location source | Google Timeline on-device export (JSON) |
| File transfer | `adb pull` from configurable on-phone path, file-picker fallback |
| Cache | Accumulated: every export merges into a persistent local history |
| Timezone handling | Trust EXIF offset by default; manual home/destination override |
| Existing GPS | Skip by default; "overwrite existing GPS" checkbox |
| Architecture | Pure Lua plugin; core modules Lightroom-independent and unit-tested |

## Components

Each component has one purpose, a defined interface, and (except LrShell) no
Lightroom dependency, so it runs under plain Lua for tests.

### AdbFetcher
Locates the `adb` binary (auto-detect on PATH, overridable in settings). Pulls
the Timeline export from a configurable on-phone path (default
`/sdcard/Download/Timeline.json`) to a temp file. Distinguishes error cases: no
adb binary, no device attached, file not found on device — each with a clear,
actionable message.

### TimelineParser
Parses Google Timeline JSON into a sorted list of `(utc_seconds, lat, lon)`
track points. Supports:
- **On-device export format** (current): `semanticSegments` — `timelinePath`
  point lists and `visit` place locations — plus `rawSignals` position records.
- **Legacy Takeout format:** `locations[]` with `latitudeE7` / `longitudeE7` /
  `timestamp`.

Format is auto-detected. Unrecognized files produce an error naming the two
supported formats.

### HistoryCache
A persistent file in the plugin's data directory holding the merged, deduped,
time-sorted track. Each parsed export is merged in (union by timestamp).
Exposes: merge(points), coverage summary (date range, point count), and the
track for matching. Old photos can be geotagged with no phone connected, as
long as some past export covered their date range.

### Matcher
Given a photo's UTC time and the track: binary-search for the bracketing
points. If the bracket gap ≤ tolerance, linearly interpolate lat/lon between
them. Else if the nearest single point is within tolerance, use it. Else
report "no match". Tolerance defaults to 15 minutes, adjustable in the dialog.

### TimeResolver
Converts a photo's capture time to UTC seconds:
- Mode "EXIF" (default): use the photo's EXIF timezone offset (from
  Lightroom's ISO8601 capture-time metadata) when present; fall back to the
  configured home timezone when absent, and count these photos for the summary.
- Mode "override": ignore EXIF; apply an explicit offset (home or destination —
  same code path, the distinction is UX only).
- In all modes, apply the clock-drift correction (seconds) last.

### LrShell (Lightroom adapter)
The only Lightroom-dependent layer: plugin manifest (`Info.lua`), the run
dialog (LrView), reading selected photos and capture-time metadata, progress
scope, writing GPS via `photo:setRawMetadata('gps', {latitude, longitude})`
inside a catalog write access block, settings persistence (LrPrefs), and the
summary dialog.

## Run dialog

```
Location history ────────────────────────────────────────
 Cache: 48,213 points, 2024-01-03 → 2026-07-08
 [ Pull latest from phone (ADB) ]  [ Import file… ]

Camera time ─────────────────────────────────────────────
 (•) Camera's timezone setting is correct
     Uses each photo's EXIF offset; photos without one
     fall back to the home timezone below.
 ( ) Clock was on home time          [ UTC+06:00 ▾ ]
 ( ) Clock was on destination time   [ UTC-08:00 ▾ ]
 Clock drift correction: [ 0 ] seconds

Matching ────────────────────────────────────────────────
 Maximum time gap: [ 15 ] minutes
 [ ] Overwrite existing GPS coordinates

              [ Cancel ]  [ Geotag 220 photos ]
```

- Both timezone dropdowns list UTC offsets from −12:00 to +14:00 including
  the :30 and :45 offsets. The **home** value persists across runs (one-time
  setup); the **destination** value prefills from last use but is expected to
  change per trip.
- Radio choice, drift, gap, and overwrite settings persist across runs
  (radio persists so repeat runs on the same trip are one click).
- DST is the user's responsibility when picking an offset (documented in the
  README). Timezone-database names are a possible future enhancement, not in
  scope.
- One camera-time choice applies to the whole run. Mixed selections (home
  shoot + clock-changed trip) are handled by running the plugin twice.

## Matching & writing behavior

- Photos with existing GPS are skipped unless "overwrite" is checked.
- Unmatched photos are never written — no guessing.
- Writes happen in a single catalog write-access block with a progress scope;
  only `gps` metadata is touched.
- Summary reports: tagged, skipped (had GPS), no match, and (if any) "N photos
  had no EXIF timezone — assumed home UTC+HH:MM", plus first/last matched
  coordinates so a timezone mistake is visible before trusting the run.

## Error handling

| Situation | Behavior |
|---|---|
| adb not found / no device | Dialog message with hint; file picker still works |
| Export file missing on phone | Message naming the expected path and how to export |
| Unparseable JSON | Error naming the supported Timeline formats |
| Photo outside history coverage | Counted as "no match"; coverage range shown in dialog |
| Empty selection | Dialog explains to select photos in Library first |

## Testing

- Core modules (TimelineParser, HistoryCache, Matcher, TimeResolver) are plain
  Lua with busted unit tests and committed sample-fixture Timeline files (both
  formats), run on GitHub Actions.
- LrShell is kept thin; it is exercised manually in Lightroom (SDK has no test
  harness).

## Open-source packaging

- MIT license.
- README: install steps, enabling USB debugging, exporting Timeline data,
  the timezone model (why home/destination override exists), and the DST note.
- Repo layout: `PhoneGeotagger.lrplugin/` (plugin, including vendored pure-Lua
  JSON parser), `spec/` (busted tests + fixtures), `docs/`.

## Out of scope (YAGNI)

- Altitude, heading, or reverse-geocoded place names.
- Per-photo timezone inference or auto-detecting clock offset.
- Timezone-database (DST-aware) support.
- Triggering the Timeline export from the computer (Android requires a tap).
- Writing EXIF directly to files (Lightroom owns metadata writing).
