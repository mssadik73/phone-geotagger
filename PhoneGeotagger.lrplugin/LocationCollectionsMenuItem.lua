local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"

local collection_name = require "collection_name"
local LocationDialog = require "LocationDialog"

local FLUSH_SIZE = 500

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

    local meta = catalog:batchGetFormattedMetadata(photos,
      { "location", "city", "stateProvince", "country" })

    local set
    catalog:withWriteAccessDo("Location collections set", function()
      set = catalog:createCollectionSet(settings.set_name, nil, true)
    end)

    local colls = {}
    local pending = {}
    local pending_n = 0
    local added, unresolved = 0, 0

    local function flush()
      if pending_n == 0 then return end
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

    progress = LrProgressScope { title = "Building location collections" }
    progress:setCancelable(true)

    for i, photo in ipairs(photos) do
      if progress:isCanceled() then break end
      local m = meta[photo] or {}
      local place = {
        poi = m.location, city = m.city, state = m.stateProvince, country = m.country,
      }
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
        .. "%d had no resolved location (re-geotag them first).",
        added, n_colls, settings.set_name, unresolved), "info")
  end)
  if progress then progress:done() end
  if not ok then
    LrDialogs.message("Create Location Collections",
      "The command failed: " .. tostring(err), "critical")
  end
end)
