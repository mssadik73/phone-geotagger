local smartcoll_rules = require "smartcoll_rules"

describe("smartcoll_rules.build", function()
  it("builds a compound Sublocation AND City rule", function()
    local d = smartcoll_rules.build("Venice Beach", "Los Angeles")
    assert.equals("intersect", d.combine)
    assert.equals(2, #d)
    assert.same({ criteria = "location", operation = "==", value = "Venice Beach" }, d[1])
    assert.same({ criteria = "city", operation = "==", value = "Los Angeles" }, d[2])
  end)

  it("omits the city criterion when city is nil", function()
    local d = smartcoll_rules.build("Downtown", nil)
    assert.equals(1, #d)
    assert.same({ criteria = "location", operation = "==", value = "Downtown" }, d[1])
  end)

  it("omits the city criterion when city is empty", function()
    local d = smartcoll_rules.build("Downtown", "")
    assert.equals(1, #d)
  end)
end)

describe("smartcoll_rules.names", function()
  it("uses the bare sublocation when it is unique", function()
    local out = smartcoll_rules.names({
      { sublocation = "Venice Beach", city = "Los Angeles" },
      { sublocation = "Hollywood", city = "Los Angeles" },
    })
    assert.equals("Venice Beach", out[1].name)
    assert.equals("Hollywood", out[2].name)
  end)

  it("disambiguates a sublocation shared by two cities", function()
    local out = smartcoll_rules.names({
      { sublocation = "Downtown", city = "Los Angeles" },
      { sublocation = "Downtown", city = "San Diego" },
    })
    assert.equals("Downtown (Los Angeles)", out[1].name)
    assert.equals("Downtown (San Diego)", out[2].name)
  end)
end)
