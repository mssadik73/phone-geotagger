-- Shared filesystem paths for the plugin (Lightroom-dependent).

local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local plugin_paths = {}

local function data_dir()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return dir
end

-- Accumulated Timeline history (points + visits), JSON. "-v2" because the
-- format changed from a points-only CSV to a JSON object with visits/placeIds.
function plugin_paths.cache_path()
  return LrPathUtils.child(data_dir(), "history-v2.json")
end

-- Resolution cache: placeId/coordinate -> resolved place, JSON.
function plugin_paths.resolve_cache_path()
  return LrPathUtils.child(data_dir(), "resolve-v1.json")
end

return plugin_paths
