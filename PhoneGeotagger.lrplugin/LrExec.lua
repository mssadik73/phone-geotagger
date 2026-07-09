-- Runs a shell command and captures combined stdout/stderr, which
-- LrTasks.execute alone cannot do. Must be called from an async task.

local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local LrExec = {}

function LrExec.execute(cmd)
  local out = LrPathUtils.child(
    LrPathUtils.getStandardFilePath("temp"),
    string.format("phone_geotagger_out_%d.txt", math.random(1e9)))
  local full = cmd .. ' > "' .. out .. '" 2>&1'
  if WIN_ENV then
    full = '"' .. full .. '"' -- cmd.exe strips the outer quotes
  end
  local status = LrTasks.execute(full)
  local text = ""
  if LrFileUtils.exists(out) then
    text = LrFileUtils.readFile(out) or ""
    LrFileUtils.delete(out)
  end
  return status, text
end

return LrExec
