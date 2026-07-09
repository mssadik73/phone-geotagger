# Remove ADB Pull — Design

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan
**Modifies:** the shipped Phone Geotagger plugin (v1 geotagging)

## Motivation

The ADB pull was the biggest setup hurdle: it required Android platform-tools,
USB debugging, an authorized device, and (on macOS) the full adb path because
Lightroom doesn't inherit the shell PATH. Since the plugin already has an
"Import file…" button, the simpler model is: the user gets the Google Timeline
JSON off their phone by whatever means they prefer (e.g. export to Google Drive
and let desktop sync bring it to the computer), then imports it.

## What changes

### Removed
- `PhoneGeotagger.lrplugin/adb_client.lua` and `spec/adb_client_spec.lua`
  (the whole module and its tests). Suite goes 95 → 87.
- In `PhoneGeotagger.lrplugin/GeotagDialog.lua`:
  - the "Pull latest from phone (ADB)" push-button and its async pull action;
  - the "adb path" edit field and the "on-phone export path" edit field;
  - the `props.adb_path` / `props.phone_path` bindings and their
    `prefs.adb_path` / `prefs.phone_path` persistence;
  - the now-unused `require "adb_client"` and `require "LrExec"`.

### Kept (explicitly not part of ADB)
- `LrExec.lua` and `clipboard.lua` — the correction feature's map picker reads
  the clipboard via `LrExec.execute`; `CorrectDialog.lua` still requires
  `LrExec`. Untouched.
- The **"Import file…"** button in `GeotagDialog.lua` becomes the only way to
  load a Timeline export. Its behavior (parse → merge into the history cache →
  update the coverage line) is unchanged.
- `require "LrTasks"` stays in `GeotagDialog.lua` (the Import action runs in an
  async task).
- Everything else: correction feature, location collections, the
  geotagging/matching core, and the persistent history cache.

## Resulting dialog

The "Location history" group box simplifies to two rows: the cache-coverage
static text and a single **Import file…** button. The Camera time, Matching,
and overwrite sections are unchanged.

## README changes

- Remove the ADB pull step from "How it works" and the "install platform-tools
  / enable USB debugging" setup from Installation.
- Reframe the workflow: export the Timeline JSON from the phone by any means,
  then **Import file…** in the plugin.
- Add a concrete suggested method: on the phone, export Timeline data to
  **Google Drive**; let **Google Drive desktop sync** bring the file to the
  computer; then Import it in Lightroom.

## Not changed

- Plugin name "Phone Geotagger" / menu title "Geotag from Phone Timeline…" /
  repo `phone-geotagger` — still accurate; only the transfer mechanism changes.
- No behavior change to matching, timezone handling, caching, or the other
  three commands.

## Testing

- Full busted suite green at 87 (the 8 adb_client tests are removed with the
  module; no other test changes).
- `luac -p` clean on the edited `GeotagDialog.lua`.
- Manual (Lightroom, owner): the dialog shows only Import file…; importing a
  Timeline JSON still populates the cache and geotags; the correction feature's
  map picker (which shares LrExec) still works.
