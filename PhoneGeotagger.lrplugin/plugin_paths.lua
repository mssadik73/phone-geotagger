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

-- Absolute path to the accumulated GPS history cache CSV.
function plugin_paths.cache_path()
  return LrPathUtils.child(data_dir(), "history.csv")
end

-- Absolute path to the reverse-geocode (coordinate -> place) cache JSON.
function plugin_paths.geocode_cache_path()
  return LrPathUtils.child(data_dir(), "geocode.json")
end

return plugin_paths
