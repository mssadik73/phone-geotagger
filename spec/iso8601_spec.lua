local iso8601 = require "iso8601"

describe("iso8601.parse", function()
  it("parses the Unix epoch", function()
    local naive, offset = iso8601.parse("1970-01-01T00:00:00Z")
    assert.equals(0, naive)
    assert.equals(0, offset)
  end)

  it("parses a timestamp with a negative offset", function()
    local naive, offset = iso8601.parse("2024-05-10T14:05:00.000-07:00")
    assert.equals(1715349900, naive)   -- wall clock as-if-UTC
    assert.equals(-25200, offset)
    assert.equals(1715375100, naive - offset)  -- true UTC
  end)

  it("parses a compact offset without a colon", function()
    local naive, offset = iso8601.parse("2025-01-01T00:00:00+0630")
    assert.equals(1735689600, naive)
    assert.equals(23400, offset)
  end)

  it("returns nil offset when the string has none", function()
    local naive, offset = iso8601.parse("2016-02-29T12:00:00")
    assert.equals(1456747200, naive)   -- leap day handled
    assert.is_nil(offset)
  end)

  it("ignores fractional seconds", function()
    local naive = iso8601.parse("1970-01-01T00:00:01.999Z")
    assert.equals(1, naive)
  end)

  it("rejects garbage", function()
    local naive, err = iso8601.parse("not a date")
    assert.is_nil(naive)
    assert.is_string(err)
  end)

  it("rejects non-strings", function()
    local naive, err = iso8601.parse(nil)
    assert.is_nil(naive)
    assert.is_string(err)
  end)
end)
