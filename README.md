# Phone Geotagger for Lightroom Classic

Geotag your camera photos using the location history already on your Android
phone. No subscription services, no uploading your photos anywhere — your
phone's Google Timeline is the GPS track logger you've been carrying all
along.

## How it works

1. On your phone, export your Timeline data
   (**Settings → Location → Timeline → Export Timeline data**) to a JSON file,
   and get that file onto your computer by whatever means you prefer (see
   [Getting the Timeline file to your computer](#getting-the-timeline-file-to-your-computer)).
2. In Lightroom Classic, select photos and run
   **Library → Plug-in Extras → Geotag from Phone Timeline...**
3. Click **Import file…** and choose your Timeline export.
4. Click **Geotag**. Each photo's capture time is converted to UTC and matched
   against your location track; matched photos get GPS coordinates written to
   the catalog.

Every export you import is merged into a local **history cache**, so you can
geotag old photos any time — as long as some past export covered those dates.

## Getting the Timeline file to your computer

Any method works — the plugin just needs the JSON file on disk. A convenient
one:

1. On the phone, export the Timeline data and save/share it to **Google
   Drive**.
2. Install **Google Drive for desktop** and let it sync, so the file appears
   in your Google Drive folder on the computer automatically.
3. In the plugin, **Import file…** and browse to the synced file.

You can equally AirDrop it, email it to yourself, copy it over USB as a plain
file, or use any cloud service — there's no phone connection or special setup
required.

## Correcting a wrong geotag

Google Timeline sometimes snaps a location to a nearby-but-wrong place. Two
commands fix that:

1. Select one photo carrying the bad tag and run **Library → Plug-in Extras →
   Find Photos With This Geotag**. Every photo within 25 m of it is selected
   in the grid. Deselect any that don't belong.
2. Run **Correct Geotag of Selection...**. Choose the true location either
   from nearby Timeline history points or with the built-in map picker:
   **Open map picker** launches a map in your browser with a pin on the
   current location — drag it to the correct spot (or search a place), then
   back in Lightroom click **Use location from map**. Click **Apply** to write
   the corrected coordinate to every selected photo.

The map picker hands the coordinate back through your system clipboard, so no
typing is needed. The corrected coordinates are written to the catalog; use
**Metadata → Save Metadata to File** to push them into your files/XMP.

## Organizing photos into location collections

Turn GPS coordinates into browsable, auto-updating Smart Collections named for
real places.

1. Select geotagged photos and run **Library → Plug-in Extras → Create
   Location Collections...**.
2. The plugin reverse-geocodes each location via OpenStreetMap, writes the
   Country / State / City / Sublocation IPTC fields, and creates a **Geo
   Locations** collection set with one Smart Collection per neighborhood.

Because the collections are Smart Collections keyed on the place-name fields,
they update themselves as you geocode more photos. Locations are cached
locally, so repeat runs and photos that share a spot cost no extra lookups.

**Note on the geocoder:** the default endpoint is the public OpenStreetMap
Nominatim service, which asks for at most one request per second — the plugin
throttles accordingly. For large libraries you can point the **Geocoder
endpoint** field at your own Nominatim instance.

## Installation

1. Download or clone this repository.
2. Lightroom Classic → **File → Plug-in Manager → Add** → select the
   `PhoneGeotagger.lrplugin` folder.

No other setup is required — you just need your exported Timeline JSON on disk
(see [above](#getting-the-timeline-file-to-your-computer)).

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
- Map picker built with [Leaflet](https://leafletjs.com/) (BSD-2-Clause) and
  [OpenStreetMap](https://www.openstreetmap.org/) tiles and search.
- Reverse geocoding by [OpenStreetMap Nominatim](https://nominatim.org/).

## License

MIT — see [LICENSE](LICENSE).
