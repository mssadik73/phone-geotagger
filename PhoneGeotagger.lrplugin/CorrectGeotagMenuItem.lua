local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

local history_cache = require "history_cache"
local candidate_finder = require "candidate_finder"
local plugin_paths = require "plugin_paths"
local CorrectDialog = require "CorrectDialog"

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  if catalog:getTargetPhoto() == nil then
    LrDialogs.message("Correct Geotag",
      "Select the photos to correct in the Library grid first.", "info")
    return
  end
  local photos = catalog:getTargetPhotos()
  if not photos or #photos == 0 then
    LrDialogs.message("Correct Geotag",
      "Select the photos to correct in the Library grid first.", "info")
    return
  end

  local gps = photos[1]:getRawMetadata("gps")
  if not gps or not gps.latitude or not gps.longitude then
    LrDialogs.message("Correct Geotag",
      "The first selected photo has no geotag. Select photos that already "
      .. "have the tag you want to correct.", "info")
    return
  end

  local points = history_cache.load(plugin_paths.cache_path())
  local candidates = candidate_finder.find(points, gps.latitude, gps.longitude,
    { radius_m = 500, max = 10 })

  local result = CorrectDialog.run {
    photo_count = #photos,
    current_lat = gps.latitude,
    current_lon = gps.longitude,
    candidates = candidates,
  }
  if not result then return end

  catalog:withWriteAccessDo("Correct geotag", function()
    for _, photo in ipairs(photos) do
      photo:setRawMetadata("gps", { latitude = result.lat, longitude = result.lon })
    end
  end)

  LrDialogs.message("Correct Geotag",
    string.format("%d photo(s) re-tagged to %.5f, %.5f.",
      #photos, result.lat, result.lon), "info")
end)
