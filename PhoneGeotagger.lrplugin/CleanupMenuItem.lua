local LrApplication = import "LrApplication"
local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"
local LrPrefs = import "LrPrefs"

local place_reconcile = require "place_reconcile"
local CleanupDialog = require "CleanupDialog"

LrTasks.startAsyncTask(function()
  local ok, err = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    if catalog:getTargetPhoto() == nil then
      LrDialogs.message("Clean Up Place Names",
        "Select the photos to clean up in the Library grid first.", "info")
      return
    end
    local photos = catalog:getTargetPhotos()

    local prefs = LrPrefs.prefsForPlugin()
    local settings = CleanupDialog.run { photo_count = #photos, prefs = prefs }
    if not settings then return end

    local text = catalog:batchGetFormattedMetadata(photos,
      { "location", "city", "stateProvince", "country" })
    local raw = catalog:batchGetRawMetadata(photos,
      { "gps", "dateTimeOriginalISO8601" })

    -- Build reconcile records; skip photos without GPS.
    local records = {}
    local rec_photo = {}
    local skipped_no_gps = 0
    for _, photo in ipairs(photos) do
      local m = text[photo] or {}
      local rm = raw[photo] or {}
      local gps = rm.gps
      if gps and gps.latitude and gps.longitude then
        records[#records + 1] = {
          poi = m.location, city = m.city, state = m.stateProvince,
          country = m.country, lat = gps.latitude, lon = gps.longitude,
          time = rm.dateTimeOriginalISO8601,
        }
        rec_photo[#records] = photo
      else
        skipped_no_gps = skipped_no_gps + 1
      end
    end

    local resolved, stats = place_reconcile.reconcile(records, settings.radius_km)

    -- Collect the fields that actually change.
    local changes = {}
    for i, r in ipairs(records) do
      local w = resolved[i]
      local ch, any = {}, false
      if (w.city or "") ~= (r.city or "") then ch.city = w.city; any = true end
      if (w.state or "") ~= (r.state or "") then ch.state = w.state; any = true end
      if (w.country or "") ~= (r.country or "") then ch.country = w.country; any = true end
      if any then ch.photo = rec_photo[i]; changes[#changes + 1] = ch end
    end

    if #changes > 0 then
      catalog:withWriteAccessDo("Clean up place names", function()
        for _, ch in ipairs(changes) do
          if ch.city ~= nil then ch.photo:setRawMetadata("city", ch.city) end
          if ch.state ~= nil then ch.photo:setRawMetadata("stateProvince", ch.state) end
          if ch.country ~= nil then ch.photo:setRawMetadata("country", ch.country) end
        end
      end)
    end

    local msg = string.format(
      "Reconciled %d photo(s) across %d place(s).\n%d place(s) had conflicting values.",
      #changes, stats.groups, stats.conflicts)
    if skipped_no_gps > 0 then
      msg = msg .. string.format("\n%d photo(s) skipped (no GPS).", skipped_no_gps)
    end
    LrDialogs.message("Clean Up Place Names", msg, "info")
  end)
  if not ok then
    LrDialogs.message("Clean Up Place Names",
      "The command failed: " .. tostring(err), "critical")
  end
end)
