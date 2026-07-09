local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPrefs = import "LrPrefs"

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

  local prefs = LrPrefs.prefsForPlugin()
  local key = prefs.google_api_key
  if not key or key == "" then
    LrDialogs.message("Correct Geotag",
      "Set your Google API key in the Plug-in Manager "
      .. "(File > Plug-in Manager > Phone Geotagger) first.", "info")
    return
  end

  local result = CorrectDialog.run {
    photo_count = #photos,
    current_lat = gps.latitude,
    current_lon = gps.longitude,
    key = key,
  }
  if not result then return end

  catalog:withWriteAccessDo("Correct geotag", function()
    for _, photo in ipairs(photos) do
      photo:setRawMetadata("gps", { latitude = result.lat, longitude = result.lon })
      if result.country then photo:setRawMetadata("country", result.country) end
      if result.state then photo:setRawMetadata("stateProvince", result.state) end
      if result.city then photo:setRawMetadata("city", result.city) end
      if result.poi then photo:setRawMetadata("location", result.poi) end
    end
  end)
  LrDialogs.message("Correct Geotag", string.format(
    "%d photo(s) re-tagged to %s (%.5f, %.5f).",
    #photos, result.poi or "the selected place", result.lat, result.lon), "info")
end)
