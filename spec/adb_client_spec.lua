local adb_client = require "adb_client"

local function fake_exec(status, output)
  local calls = {}
  return function(cmd)
    calls[#calls + 1] = cmd
    return status, output
  end, calls
end

describe("adb_client", function()
  it("builds a fully quoted pull command", function()
    local cmd = adb_client.pull_command(
      "/opt/platform-tools/adb", "/sdcard/Download/Timeline.json", "/tmp/t.json")
    assert.equals(
      '"/opt/platform-tools/adb" pull "/sdcard/Download/Timeline.json" "/tmp/t.json"',
      cmd)
  end)

  it("returns true on success", function()
    local exec, calls = fake_exec(0, "1 file pulled, 0 skipped.")
    assert.is_true(adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json"))
    assert.equals(1, #calls)
  end)

  it("classifies a missing adb binary", function()
    local exec = fake_exec(127, "sh: adb: command not found")
    local ok, code, msg = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("adb_not_found", code)
    assert.matches("adb", msg)
  end)

  it("classifies the Windows missing-binary message", function()
    local exec = fake_exec(1,
      "'adb' is not recognized as an internal or external command")
    local ok, code = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("adb_not_found", code)
  end)

  it("classifies no connected device", function()
    local exec = fake_exec(1, "adb: no devices/emulators found")
    local ok, code, msg = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("no_device", code)
    assert.matches("USB debugging", msg)
  end)

  it("classifies an unauthorized device as no_device", function()
    local exec = fake_exec(1, "adb: device unauthorized.\nThis adb server's...")
    local ok, code = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("no_device", code)
  end)

  it("classifies a missing remote file", function()
    local exec = fake_exec(1,
      "adb: error: remote object '/sdcard/Download/Timeline.json' does not exist")
    local ok, code, msg = adb_client.pull(
      exec, "adb", "/sdcard/Download/Timeline.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("remote_missing", code)
    assert.matches("Timeline", msg)
  end)

  it("falls back to a generic error with the raw output", function()
    local exec = fake_exec(1, "something exploded")
    local ok, code, msg = adb_client.pull(exec, "adb", "/sdcard/x.json", "/tmp/x.json")
    assert.is_nil(ok)
    assert.equals("adb_error", code)
    assert.matches("something exploded", msg)
  end)
end)
