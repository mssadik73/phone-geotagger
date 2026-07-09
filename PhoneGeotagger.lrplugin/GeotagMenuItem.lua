local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local LrPrefs = import "LrPrefs"

local history_cache = require "history_cache"
local tz_offsets = require "tz_offsets"
local GeotagDialog = require "GeotagDialog"

local function cache_path()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return LrPathUtils.child(dir, "history.csv")
end

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local photos = catalog:getTargetPhotos()
  if not photos or #photos == 0 then
    LrDialogs.message("Phone Geotagger",
      "Select photos in the Library grid first.", "info")
    return
  end

  local prefs = LrPrefs.prefsForPlugin()
  local cpath = cache_path()
  local points = history_cache.load(cpath)

  local settings = GeotagDialog.run {
    photo_count = #photos, points = points, cache_path = cpath, prefs = prefs,
  }
  if not settings then return end

  -- Temporary: echo the chosen settings instead of geotagging (Task 9
  -- replaces this with the real pipeline).
  LrDialogs.message("Phone Geotagger (smoke test)", string.format(
    "points=%d override=%s home=%s drift=%d gap=%ds overwrite=%s",
    #settings.points,
    settings.override_offset and tz_offsets.format(settings.override_offset) or "EXIF",
    tz_offsets.format(settings.home_offset),
    settings.drift, settings.max_gap_sec, tostring(settings.overwrite)), "info")
end)
