local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"

local history_cache = require "history_cache"
local matcher = require "matcher"
local time_resolver = require "time_resolver"
local tz_offsets = require "tz_offsets"
local GeotagDialog = require "GeotagDialog"
local plugin_paths = require "plugin_paths"
local coord_round = require "coord_round"

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  if catalog:getTargetPhoto() == nil then
    LrDialogs.message("Phone Geotagger",
      "Select photos in the Library grid first.", "info")
    return
  end
  local photos = catalog:getTargetPhotos()
  if not photos or #photos == 0 then
    LrDialogs.message("Phone Geotagger",
      "Select photos in the Library grid first.", "info")
    return
  end

  local prefs = LrPrefs.prefsForPlugin()
  local cpath = plugin_paths.cache_path()
  local points = history_cache.load(cpath)

  local settings = GeotagDialog.run {
    photo_count = #photos, points = points, cache_path = cpath, prefs = prefs,
  }
  if not settings then return end
  if #settings.points == 0 then
    LrDialogs.message("Phone Geotagger",
      "No location history available. Pull from the phone or import an "
      .. "export file first.", "warning")
    return
  end

  local stats = { skipped = 0, unmatched = 0, no_time = 0, no_tz = 0 }
  local writes = {}
  local progress = LrProgressScope { title = "Geotagging from phone Timeline" }
  progress:setCancelable(true)

  for i, photo in ipairs(photos) do
    if progress:isCanceled() then break end
    progress:setPortionComplete(i - 1, #photos)

    local gps = photo:getRawMetadata("gps")
    if gps and gps.latitude and not settings.overwrite then
      stats.skipped = stats.skipped + 1
    else
      local iso = photo:getRawMetadata("dateTimeOriginalISO8601")
      if not iso or iso == "" then
        stats.no_time = stats.no_time + 1
      else
        local utc, extra = time_resolver.resolve(iso, {
          override_offset = settings.override_offset,
          home_offset = settings.home_offset,
          drift = settings.drift,
        })
        if not utc then
          stats.no_time = stats.no_time + 1
        else
          if extra == true then stats.no_tz = stats.no_tz + 1 end
          local lat, lon = matcher.match(settings.points, utc, settings.max_gap_sec)
          if lat then
            lat, lon = coord_round.round(lat, lon, settings.precision)
            writes[#writes + 1] = { photo = photo, lat = lat, lon = lon }
          else
            stats.unmatched = stats.unmatched + 1
          end
        end
      end
    end
  end

  if #writes > 0 then
    catalog:withWriteAccessDo("Geotag from Phone Timeline", function()
      for _, w in ipairs(writes) do
        w.photo:setRawMetadata("gps", { latitude = w.lat, longitude = w.lon })
      end
    end)
  end
  progress:done()

  local lines = {
    string.format("Tagged: %d", #writes),
    string.format("Skipped (already had GPS): %d", stats.skipped),
    string.format("No match in history: %d", stats.unmatched),
  }
  if stats.no_time > 0 then
    lines[#lines + 1] = string.format("No usable capture time: %d", stats.no_time)
  end
  if stats.no_tz > 0 and not settings.override_offset then
    lines[#lines + 1] = string.format(
      "No EXIF timezone (assumed home %s): %d",
      tz_offsets.format(settings.home_offset), stats.no_tz)
  end
  if #writes > 0 then
    local first, last = writes[1], writes[#writes]
    lines[#lines + 1] = string.format("First match: %.5f, %.5f (%s)",
      first.lat, first.lon, first.photo:getFormattedMetadata("fileName"))
    lines[#lines + 1] = string.format("Last match: %.5f, %.5f (%s)",
      last.lat, last.lon, last.photo:getFormattedMetadata("fileName"))
  end
  LrDialogs.message("Phone Geotagger — done", table.concat(lines, "\n"), "info")
end)
