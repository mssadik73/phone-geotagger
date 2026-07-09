local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local geocode_client = require "geocode_client"
local place_extract = require "place_extract"
local geo_cache = require "geo_cache"
local smartcoll_rules = require "smartcoll_rules"
local plugin_paths = require "plugin_paths"
local LocationDialog = require "LocationDialog"

local USER_AGENT = "PhoneGeotagger/0.1 (github.com/mssadik73/phone-geotagger)"

local function http_get(url)
  local body = LrHttp.get(url, { { field = "User-Agent", value = USER_AGENT } })
  return body
end

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  if catalog:getTargetPhoto() == nil then
    LrDialogs.message("Create Location Collections",
      "Select the photos to organize in the Library grid first.", "info")
    return
  end
  local photos = catalog:getTargetPhotos()
  local meta = catalog:batchGetRawMetadata(photos, { "gps", "city", "location" })

  -- Collect GPS photos and the unique coordinate buckets among them.
  local gps_photos = {}
  local unique = {}      -- key -> { lat, lon }
  for _, photo in ipairs(photos) do
    local m = meta[photo]
    local g = m and m.gps
    if g and g.latitude and g.longitude then
      gps_photos[#gps_photos + 1] = photo
      local k = geo_cache.key(g.latitude, g.longitude)
      if not unique[k] then unique[k] = { lat = g.latitude, lon = g.longitude } end
    end
  end
  if #gps_photos == 0 then
    LrDialogs.message("Create Location Collections",
      "None of the selected photos have GPS coordinates.", "info")
    return
  end

  local unique_count = 0
  for _ in pairs(unique) do unique_count = unique_count + 1 end

  local prefs = LrPrefs.prefsForPlugin()
  local settings = LocationDialog.run {
    photo_count = #gps_photos, unique_count = unique_count, prefs = prefs,
  }
  if not settings then return end

  -- Resolve each unique coordinate (cache first, else throttled network).
  local cache = geo_cache.load(plugin_paths.geocode_cache_path())
  local progress = LrProgressScope { title = "Looking up locations" }
  progress:setCancelable(true)
  local unresolved = 0
  local done = 0
  for k, coord in pairs(unique) do
    if progress:isCanceled() then break end
    local place = geo_cache.get(cache, coord.lat, coord.lon)
    if not place then
      local addr = geocode_client.reverse(http_get, settings.endpoint, coord.lat, coord.lon)
      place = addr and place_extract.extract(addr) or {}
      geo_cache.put(cache, coord.lat, coord.lon, place)
      LrTasks.sleep(1.1) -- Nominatim: <= 1 req/sec, only on a real lookup
    end
    if not (place.sublocation or place.city) then unresolved = unresolved + 1 end
    done = done + 1
    progress:setPortionComplete(done, unique_count)
  end
  progress:done()
  geo_cache.save(plugin_paths.geocode_cache_path(), cache)

  -- Write IPTC fields; collect distinct (sublocation, city) pairs.
  local tagged, skipped = 0, 0
  local pair_seen, pairs_list = {}, {}
  catalog:withWriteAccessDo("Write location metadata", function()
    for _, photo in ipairs(gps_photos) do
      local m = meta[photo]
      local g = m.gps
      local place = geo_cache.get(cache, g.latitude, g.longitude)
      local has_existing = (m.city and m.city ~= "") or (m.location and m.location ~= "")
      if place and place.sublocation and (settings.overwrite or not has_existing) then
        if place.country then photo:setRawMetadata("country", place.country) end
        if place.state then photo:setRawMetadata("stateProvince", place.state) end
        if place.city then photo:setRawMetadata("city", place.city) end
        photo:setRawMetadata("location", place.sublocation)
        tagged = tagged + 1
        local pk = place.sublocation .. "\0" .. (place.city or "")
        if not pair_seen[pk] then
          pair_seen[pk] = true
          pairs_list[#pairs_list + 1] =
            { sublocation = place.sublocation, city = place.city }
        end
      elseif has_existing and not settings.overwrite then
        skipped = skipped + 1
      end
    end
  end)

  -- Create / refresh the smart-collection set and members.
  local named = smartcoll_rules.names(pairs_list)
  local created = 0
  catalog:withWriteAccessDo("Create location collections", function()
    local set = catalog:createCollectionSet(settings.set_name, nil, true)
    for _, p in ipairs(named) do
      catalog:createSmartCollection(p.name, smartcoll_rules.build(p.sublocation, p.city),
        set, true)
      created = created + 1
    end
  end)

  LrDialogs.message("Create Location Collections",
    string.format(
      "Tagged %d photo(s), skipped %d (already had a location), %d unresolved.\n"
      .. "%d Smart Collection(s) under \"%s\".",
      tagged, skipped, unresolved, created, settings.set_name), "info")
end)
