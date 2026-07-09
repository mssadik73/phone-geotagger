# Phone Geotagger for Lightroom Classic

Geotag your camera photos using the location history already on your Android
phone. No subscription services, no uploading your photos anywhere — your
phone's Google Timeline is the GPS track logger you've been carrying all
along.

## How it works

1. On your phone, export your Timeline data
   (**Settings → Location → Timeline → Export Timeline data**) and save the
   JSON to `Download/Timeline.json`.
2. In Lightroom Classic, select photos and run
   **Library → Plug-in Extras → Geotag from Phone Timeline...**
3. Click **Pull latest from phone (ADB)** (or **Import file…** to browse to a
   copy of the export).
4. Click **Geotag**. Each photo's capture time is converted to UTC and matched
   against your location track; matched photos get GPS coordinates written to
   the catalog.

Every export you import is merged into a local **history cache**, so you can
geotag old photos any time without the phone connected — as long as some past
export covered those dates.

## Installation

1. Download or clone this repository.
2. Lightroom Classic → **File → Plug-in Manager → Add** → select the
   `PhoneGeotagger.lrplugin` folder.
3. For ADB pulls: install [Android platform-tools](https://developer.android.com/tools/releases/platform-tools),
   enable **USB debugging** on the phone (Settings → Developer options), and
   accept the authorization prompt when you first connect. If `adb` isn't on
   your PATH, set its full path in the plugin dialog.

The file-import path works with zero setup — you can always skip ADB and copy
the export JSON to your computer manually.

## The timezone model (please read once)

Your phone records locations in UTC. Your camera records wall-clock time.
The plugin needs to know which timezone your camera's clock was showing:

- **Camera's timezone setting is correct** (default): uses each photo's EXIF
  timezone offset. This is right for cameras that sync time from your phone —
  and also for cameras whose clock *and* timezone you simply never change,
  even when you travel (the two stay consistent, so the UTC math works out).
  Photos with no EXIF offset fall back to your home timezone below.
- **Clock was on home time**: ignores EXIF; converts using your home timezone
  (remembered between runs).
- **Clock was on destination time**: ignores EXIF; converts using the
  timezone you pick for this run — for trips where you set the camera clock
  to local time but didn't update its timezone setting.

**DST note:** the dropdowns are fixed UTC offsets, so pick the offset that was
in effect (e.g. UTC−07:00 for California in summer). One choice applies per
run — if a selection mixes shoots that need different settings, run the
plugin once per group.

The summary always shows the first and last matched coordinates — glance at
them before trusting a big run; a timezone mistake shows up as a location
hours of travel away.

## Supported Timeline formats

- **On-device export** (current Android): `semanticSegments` / `rawSignals`
- **Legacy Google Takeout** `Records.json`: `locations[]` with `latitudeE7`

## Matching behavior

- Track points bracketing the photo time are linearly interpolated when they
  are within the **maximum time gap** (default 15 minutes); otherwise the
  nearest point within the gap is used; otherwise the photo is left untouched
  and reported as "no match".
- Photos that already have GPS are skipped unless **Overwrite existing GPS
  coordinates** is checked.
- Coordinates are written to the Lightroom catalog only; use Lightroom's
  **Metadata → Save Metadata to File** to write them into your files/XMP.

## Development

Core logic is plain Lua 5.1 with no Lightroom dependencies, tested with
[busted](https://lunarmodules.github.io/busted/):

```sh
luarocks install busted
busted
```

The Lightroom-facing layer (`Info.lua`, `GeotagMenuItem.lua`,
`GeotagDialog.lua`, `LrExec.lua`) is kept thin and verified manually.

## Credits

- JSON parsing by [dkjson](http://dkolf.de/dkjson-lua/) (David Kolf, MIT).

## License

MIT — see [LICENSE](LICENSE).
