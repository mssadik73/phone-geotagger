local time_resolver = require "time_resolver"

describe("time_resolver.resolve", function()
  it("uses the embedded EXIF offset by default", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00", { home_offset = 21600 })
    assert.equals(1715375100, utc)
    assert.is_false(fallback)
  end)

  it("falls back to the home offset when EXIF has none", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00", { home_offset = 21600 })
    assert.equals(1715328300, utc) -- naive 1715349900 - 21600
    assert.is_true(fallback)
  end)

  it("lets an explicit override beat the EXIF offset", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00",
      { override_offset = -28800, home_offset = 21600 })
    assert.equals(1715378700, utc) -- naive 1715349900 + 28800
    assert.is_false(fallback)
  end)

  it("honors an explicit UTC+00:00 override", function()
    local utc, fallback = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00",
      { override_offset = 0, home_offset = 21600 })
    assert.equals(1715349900, utc) -- naive minus zero offset
    assert.is_false(fallback)
  end)

  it("subtracts clock drift (camera running fast)", function()
    local utc = time_resolver.resolve(
      "2024-05-10T14:05:00-07:00", { home_offset = 0, drift = 60 })
    assert.equals(1715375040, utc)
  end)

  it("propagates parse errors", function()
    local utc, err = time_resolver.resolve("garbage", { home_offset = 0 })
    assert.is_nil(utc)
    assert.is_string(err)
  end)
end)
