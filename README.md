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
   against your location track; matched photos get GPS coordinates **and a place
   name** (POI / City / State / Country) written to the catalog.

Every export you import is merged into a local **history cache**, so you can
geotag old photos any time — as long as some past export covered those dates.

**One-time setup:** create a Google Cloud project, enable the **Places API
(New)** and the **Geocoding API**, create an API key, and paste it into
**File → Plug-in Manager → Phone Geotagger → Google API key**. Geotagging
and correcting both resolve place names through Google (these are billable
APIs; results are cached so each place is looked up once).

### How a place name is resolved

For each matched photo the plugin resolves the place through a ladder, stopping
at the first tier that yields a name:

1. **Timeline place ID** — when the photo falls inside a Timeline *visit* that
   carries Google's `placeId`, the exact place is looked up with **Place
   Details** (best POI name, e.g. `Griffith Observatory`). The GPS snaps to the
   visit's coordinate.
2. **Nearest notable place** — when the coordinate has no place ID (not every
   visit does, and photos taken while moving never do), **Nearby Search** finds
   the closest landmark within ~150 m from a curated list (attractions, parks,
   museums, monuments…). The photo keeps its own GPS; only the *name* is
   borrowed.
3. **Reverse geocode** — if nothing notable is nearby, the coordinate is reverse
   geocoded for **City / State / Country**.

Whatever is found is written to the photo's IPTC fields — POI →
Sublocation, plus City, State/Province, and Country — and later drives the
offline collection names. Every unique spot (rounded to ~11 m) is looked up
once and cached in `resolve-v1.json`, so repeat runs and photos that share a
location cost no extra calls.

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

Google Timeline sometimes tags a photo to a nearby-but-wrong place. To fix a
group:

1. Select one photo with the bad tag and run **Library → Plug-in Extras →
   Find Photos With This Geotag** to select every photo within 25 m. Deselect
   any that don't belong.
2. Run **Correct Geotag of Selection...**, type the correct place, click
   **Search**, pick it from the Google results, and click **Apply**. The
   place's coordinate and its name (Sublocation / City / State / Country) are
   written to every selected photo.

The corrected data is written to the catalog; use **Metadata → Save Metadata
to File** to push it into your files/XMP.

## Organizing photos into location collections

Geotagging writes each photo's place (POI, City, State, Country) into its
IPTC metadata. This command turns that into collections — entirely offline,
no API calls.

1. Select geotagged photos and run **Library → Plug-in Extras → Create
   Location Collections...**.
2. Choose the **collection name format** (primary + optional secondary of
   POI / City / State / Country; default `POI, City`).
3. Each photo is added to a collection named from its stored place (e.g.
   `Griffith Observatory, Los Angeles`), all under a **Geo Locations** set.

These are regular collections (a snapshot), so re-run after geotagging more
photos. Photos geotagged before place resolution existed have no stored place
— re-geotag them to populate it.

## Installation

1. Download or clone this repository.
2. Lightroom Classic → **File → Plug-in Manager → Add** → select the
   `PhoneGeotagger.lrplugin` folder.

You also need your exported Timeline JSON on disk
(see [above](#getting-the-timeline-file-to-your-computer)) and a Google API key
set in the Plug-in Manager (see [One-time setup](#how-it-works)).

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

The Lightroom-facing layer (`Info.lua`, `PluginInfoProvider.lua`,
`GeotagMenuItem.lua`, `GeotagDialog.lua`, and the other `*MenuItem.lua` /
`*Dialog.lua` files) is kept thin and verified manually.

## Credits

- JSON parsing by [dkjson](http://dkolf.de/dkjson-lua/) (David Kolf, MIT).
- Place names and geocoding by [Google Maps Platform](https://developers.google.com/maps).

## License

MIT — see [LICENSE](LICENSE).
