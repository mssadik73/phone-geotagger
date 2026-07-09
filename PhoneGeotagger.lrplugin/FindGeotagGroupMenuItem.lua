local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

local geo_group = require "geo_group"

local TOLERANCE_M = 25

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local example = catalog:getTargetPhoto()
  if not example then
    LrDialogs.message("Find Photos With This Geotag",
      "Select one photo that has the geotag you want to match.", "info")
    return
  end

  local gps = example:getRawMetadata("gps")
  if not gps or not gps.latitude or not gps.longitude then
    LrDialogs.message("Find Photos With This Geotag",
      "This photo has no geotag to match.", "info")
    return
  end

  local all = catalog:getAllPhotos()
  local meta = catalog:batchGetRawMetadata(all, { "gps" })
  local matches = {}
  for photo, m in pairs(meta) do
    local g = m.gps
    if g and g.latitude and g.longitude then
      if geo_group.haversine(gps.latitude, gps.longitude, g.latitude, g.longitude)
          <= TOLERANCE_M then
        matches[#matches + 1] = photo
      end
    end
  end

  catalog:setSelectedPhotos(matches[1] or example, matches)
  LrDialogs.message("Find Photos With This Geotag",
    string.format("%d photo(s) share this geotag (within %d m). Review the "
      .. "selection and deselect any that don't belong, then run "
      .. "\"Correct Geotag of Selection...\".", #matches, TOLERANCE_M), "info")
end)
