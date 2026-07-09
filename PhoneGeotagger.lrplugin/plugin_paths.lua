-- Shared filesystem paths for the plugin (Lightroom-dependent).

local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local plugin_paths = {}

-- Absolute path to the accumulated history cache CSV.
function plugin_paths.cache_path()
  local base = LrPathUtils.getStandardFilePath("appData")
    or LrPathUtils.getStandardFilePath("home")
  local dir = LrPathUtils.child(base, "PhoneGeotagger")
  LrFileUtils.createAllDirectories(dir)
  return LrPathUtils.child(dir, "history.csv")
end

return plugin_paths
