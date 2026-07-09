local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local geocode_client = require "geocode_client"
local place_extract = require "place_extract"
local geo_cache = require "geo_cache"
local collection_name = require "collection_name"
local plugin_paths = require "plugin_paths"
local LocationDialog = require "LocationDialog"

local USER_AGENT = "PhoneGeotagger/0.1 (github.com/mssadik73/phone-geotagger)"
local FLUSH_SIZE = 500

local function http_get(url)
  local body = LrHttp.get(url, { { field = "User-Agent", value = USER_AGENT } })
  return body
end

LrTasks.startAsyncTask(function()
  local progress
  local ok, err = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    if catalog:getTargetPhoto() == nil then
      LrDialogs.message("Create Location Collections",
        "Select the photos to organize in the Library grid first.", "info")
      return
    end
    local photos = catalog:getTargetPhotos()

    local prefs = LrPrefs.prefsForPlugin()
    local settings = LocationDialog.run { photo_count = #photos, prefs = prefs }
    if not settings then return end
    local fmt = { primary = settings.primary, secondary = settings.secondary }

    local cache_path = plugin_paths.geocode_cache_path()
    local cache = geo_cache.load(cache_path)

    -- Ensure the parent collection set exists.
    local set
    catalog:withWriteAccessDo("Location collections set", function()
      set = catalog:createCollectionSet(settings.set_name, nil, true)
    end)

    local colls = {}   -- name -> LrCollection (created lazily, reused across flushes)
    local pending = {} -- name -> { photo, ... } buffered for the next flush
    local pending_n = 0
    local added, unresolved, no_gps = 0, 0, 0

    local function flush()
      if pending_n > 0 then
        catalog:withWriteAccessDo("Add photos to location collections", function()
          for name, list in pairs(pending) do
            local coll = colls[name]
            if not coll then
              coll = catalog:createCollection(name, set, true)
              colls[name] = coll
            end
            coll:addPhotos(list)
          end
        end)
        pending = {}
        pending_n = 0
      end
      geo_cache.save(cache_path, cache)
    end

    progress = LrProgressScope { title = "Building location collections" }
    progress:setCancelable(true)

    for i, photo in ipairs(photos) do
      if progress:isCanceled() then break end
      local g = photo:getRawMetadata("gps")
      if not (g and g.latitude and g.longitude) then
        no_gps = no_gps + 1
      else
        local place = geo_cache.get(cache, g.latitude, g.longitude)
        if not place then
          local addr = geocode_client.reverse(http_get, settings.endpoint,
            g.latitude, g.longitude)
          if addr then
            place = place_extract.extract(addr)
            geo_cache.put(cache, g.latitude, g.longitude, place)
          else
            place = {}
          end
          LrTasks.sleep(1.1) -- Nominatim: <= 1 req/sec, only on a real lookup
        end
        local name = collection_name.of(place, fmt)
        if name then
          pending[name] = pending[name] or {}
          pending[name][#pending[name] + 1] = photo
          pending_n = pending_n + 1
          added = added + 1
          if pending_n >= FLUSH_SIZE then flush() end
        else
          unresolved = unresolved + 1
        end
      end
      progress:setPortionComplete(i, #photos)
    end

    flush()
    progress:done()
    progress = nil

    local n_colls = 0
    for _ in pairs(colls) do n_colls = n_colls + 1 end
    LrDialogs.message("Create Location Collections",
      string.format(
        "Added %d photo(s) to %d location collection(s) under \"%s\".\n"
        .. "%d unresolved, %d without GPS.",
        added, n_colls, settings.set_name, unresolved, no_gps), "info")
  end)
  if progress then progress:done() end
  if not ok then
    LrDialogs.message("Create Location Collections",
      "The command failed: " .. tostring(err), "critical")
  end
end)
