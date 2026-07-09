local tz_offsets = require "tz_offsets"

describe("tz_offsets", function()
  it("formats offsets", function()
    assert.equals("UTC+06:00", tz_offsets.format(21600))
    assert.equals("UTC-09:30", tz_offsets.format(-34200))
    assert.equals("UTC+00:00", tz_offsets.format(0))
  end)

  it("spans UTC-12:00 to UTC+14:00 ascending", function()
    local items = tz_offsets.items()
    assert.equals(-43200, items[1].value)
    assert.equals(50400, items[#items].value)
    for i = 2, #items do
      assert.is_true(items[i].value > items[i - 1].value)
    end
  end)

  it("includes the odd real-world offsets", function()
    local values = {}
    for _, item in ipairs(tz_offsets.items()) do values[item.value] = item.title end
    assert.equals("UTC+05:45", values[20700])  -- Nepal
    assert.equals("UTC+05:30", values[19800])  -- India
    assert.equals("UTC-03:30", values[-12600]) -- Newfoundland
    assert.equals("UTC+12:45", values[45900])  -- Chatham
  end)
end)
