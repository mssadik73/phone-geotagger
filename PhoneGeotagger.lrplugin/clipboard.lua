-- Reads the system clipboard via an injected exec (Lightroom-free, testable).

local clipboard = {}

function clipboard.read_command(is_windows)
  if is_windows then
    return 'powershell -command "Get-Clipboard"'
  end
  return "pbpaste"
end

-- exec: function(command) -> exit_status, output_text
-- Returns the clipboard text, trimmed of surrounding whitespace/newlines.
function clipboard.read(exec, is_windows)
  local _, out = exec(clipboard.read_command(is_windows))
  out = out or ""
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

return clipboard
