local clipboard = require "clipboard"

local function fake_exec(output)
  local calls = {}
  return function(cmd)
    calls[#calls + 1] = cmd
    return 0, output
  end, calls
end

describe("clipboard", function()
  it("uses pbpaste on macOS", function()
    assert.equals("pbpaste", clipboard.read_command(false))
  end)

  it("uses PowerShell Get-Clipboard on Windows", function()
    assert.equals('powershell -command "Get-Clipboard"', clipboard.read_command(true))
  end)

  it("reads and trims the clipboard text", function()
    local exec, calls = fake_exec("23.8103, 90.4125\n")
    assert.equals("23.8103, 90.4125", clipboard.read(exec, false))
    assert.equals("pbpaste", calls[1])
  end)

  it("returns empty string for empty clipboard", function()
    local exec = fake_exec("")
    assert.equals("", clipboard.read(exec, false))
  end)
end)
