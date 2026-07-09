local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"

local history_cache = require "history_cache"
local visit_matcher = require "visit_matcher"
local matcher = require "matcher"
local coord_round = require "coord_round"
local time_resolver = require "time_resolver"
local google_geo = require "google_geo"
local geo_cache = require "geo_cache"
local plugin_paths = require "plugin_paths"
local GeotagDialog = require "GeotagDialog"

local function http_get(url, headers)
  return (LrHttp.get(url, headers))
end

LrTasks.startAsyncTask(function()
  local progress
  local ok, err = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    if catalog:getTargetPhoto() == nil then
      LrDialogs.message("Geotag from Phone Timeline",
        "Select photos in the Library grid first.", "info")
      return
    end

    local prefs = LrPrefs.prefsForPlugin()
    local key = prefs.google_api_key
    if not key or key == "" then
      LrDialogs.message("Geotag from Phone Timeline",
        "Set your Google API key in the Plug-in Manager "
        .. "(File > Plug-in Manager > Phone Geotagger) first.", "info")
      return
    end

    local photos = catalog:getTargetPhotos()
    local cpath = plugin_paths.cache_path()
    local history = history_cache.load(cpath)

    local settings = GeotagDialog.run {
      photo_count = #photos, history = history, cache_path = cpath, prefs = prefs,
    }
    if not settings then return end
    history = settings.history

    local resolve_path = plugin_paths.resolve_cache_path()
    local resolve = geo_cache.load(resolve_path)

    -- Resolve a placeId (cached).
    local function resolve_place(place_id)
      local k = "pid:" .. place_id
      local p = resolve[k]
      if not p then
        p = google_geo.place_details(http_get, key, place_id)
        if p then resolve[k] = p end
      end
      return p
    end
    -- Reverse-geocode a coordinate (cached).
    local function resolve_coord(lat, lon)
      local k = geo_cache.key(lat, lon)
      local p = resolve[k]
      if not p then
        p = google_geo.reverse(http_get, key, lat, lon)
        if p then resolve[k] = p end
      end
      return p
    end

    local stats = { skipped = 0, unmatched = 0, no_time = 0, resolved = 0 }
    local writes = {}
    progress = LrProgressScope { title = "Geotagging from phone Timeline" }
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
          local utc = time_resolver.resolve(iso, {
            override_offset = settings.override_offset,
            home_offset = settings.home_offset,
            drift = settings.drift,
          })
          if not utc then
            stats.no_time = stats.no_time + 1
          else
            local lat, lon, place
            local v = visit_matcher.match(history.visits, utc)
            if v then
              lat, lon = v.lat, v.lon
              if v.place_id then place = resolve_place(v.place_id) end
            else
              lat, lon = matcher.match(history.points, utc, settings.max_gap_sec)
              if lat then place = resolve_coord(lat, lon) end
            end
            if lat then
              lat, lon = coord_round.round(lat, lon, settings.precision)
              if place then stats.resolved = stats.resolved + 1 end
              writes[#writes + 1] = { photo = photo, lat = lat, lon = lon, place = place }
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
          local p = w.place
          if p then
            if p.country then w.photo:setRawMetadata("country", p.country) end
            if p.state then w.photo:setRawMetadata("stateProvince", p.state) end
            if p.city then w.photo:setRawMetadata("city", p.city) end
            if p.poi then w.photo:setRawMetadata("location", p.poi) end
          end
        end
      end)
    end
    geo_cache.save(resolve_path, resolve)
    progress:done()
    progress = nil

    LrDialogs.message("Geotag from Phone Timeline — done", string.format(
      "Tagged: %d (%d with a place)\nSkipped (had GPS): %d\n"
      .. "No match: %d\nNo capture time: %d",
      #writes, stats.resolved, stats.skipped, stats.unmatched, stats.no_time), "info")
  end)
  if progress then progress:done() end
  if not ok then
    LrDialogs.message("Geotag from Phone Timeline",
      "The command failed: " .. tostring(err), "critical")
  end
end)
