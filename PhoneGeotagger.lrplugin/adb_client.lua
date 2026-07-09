-- Builds and interprets adb commands. Execution is injected (exec function)
-- so this module stays Lightroom-free and unit-testable.

local adb_client = {}

local function q(s) return '"' .. s .. '"' end

function adb_client.pull_command(adb_path, remote_path, local_path)
  return q(adb_path) .. " pull " .. q(remote_path) .. " " .. q(local_path)
end

-- exec: function(command) -> exit_status, output_text
-- Returns true — or nil, code, message where code is one of
-- "adb_not_found" | "no_device" | "remote_missing" | "adb_error".
function adb_client.pull(exec, adb_path, remote_path, local_path)
  local status, output = exec(adb_client.pull_command(adb_path, remote_path, local_path))
  if status == 0 then return true end
  local low = (output or ""):lower()
  if status == 127
      or low:find("command not found", 1, true)
      or low:find("not recognized", 1, true) then
    return nil, "adb_not_found",
      "Could not run adb ('" .. adb_path .. "'). Install Android platform-tools "
      .. "or set the full adb path in the dialog."
  end
  if low:find("no devices", 1, true)
      or low:find("device offline", 1, true)
      or low:find("unauthorized", 1, true) then
    return nil, "no_device",
      "No Android device reachable over ADB. Connect the phone, enable "
      .. "USB debugging, and accept the authorization prompt on the phone."
  end
  if low:find("does not exist", 1, true) or low:find("no such file", 1, true) then
    return nil, "remote_missing",
      "No export found at '" .. remote_path .. "' on the phone. Export your "
      .. "Timeline data (Settings > Location > Timeline > Export) to that "
      .. "path, or correct the on-phone path in the dialog."
  end
  return nil, "adb_error",
    "adb failed (exit " .. tostring(status) .. "): " .. (output or "")
end

return adb_client
