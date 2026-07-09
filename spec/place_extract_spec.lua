local place_extract = require "place_extract"

describe("place_extract.extract", function()
  it("picks neighbourhood as sublocation and city", function()
    local p = place_extract.extract({
      neighbourhood = "Venice Beach", suburb = "Venice",
      city = "Los Angeles", state = "California", country = "United States",
    })
    assert.equals("Venice Beach", p.sublocation)
    assert.equals("Los Angeles", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
  end)

  it("falls back through the neighbourhood chain to suburb", function()
    local p = place_extract.extract({ suburb = "Hollywood", city = "Los Angeles" })
    assert.equals("Hollywood", p.sublocation)
  end)

  it("returns nil sublocation when there is no neighbourhood", function()
    local p = place_extract.extract({ village = "Lone Pine", state = "California" })
    assert.equals("Lone Pine", p.city)
    assert.is_nil(p.sublocation)
  end)

  it("leaves city nil but keeps sublocation when only a neighbourhood exists", function()
    local p = place_extract.extract({ neighbourhood = "Downtown", country = "X" })
    assert.equals("Downtown", p.sublocation)
    assert.is_nil(p.city)
  end)

  it("preserves non-ASCII names", function()
    local p = place_extract.extract({ suburb = "Fenerbahçe", city = "İstanbul" })
    assert.equals("Fenerbahçe", p.sublocation)
    assert.equals("İstanbul", p.city)
  end)

  it("returns an empty table for non-table input", function()
    assert.same({}, place_extract.extract(nil))
  end)

  it("ignores empty-string fields", function()
    local p = place_extract.extract({ neighbourhood = "", suburb = "Venice", city = "" })
    assert.equals("Venice", p.sublocation)
    assert.is_nil(p.city)
  end)

  it("treats empty-string country and state as absent", function()
    local p = place_extract.extract({ country = "", state = "California", city = "LA" })
    assert.is_nil(p.country)
    assert.equals("California", p.state)
  end)
end)
