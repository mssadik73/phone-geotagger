local collection_name = require "collection_name"

describe("collection_name.auto", function()
  it("pairs neighborhood with city", function()
    assert.equals("Venice Beach, Los Angeles", collection_name.auto({
      poi = "Venice Beach", city = "Los Angeles",
      state = "California", country = "United States" }))
  end)

  it("pairs city with state when there is no neighborhood", function()
    assert.equals("Los Angeles, California", collection_name.auto({
      city = "Los Angeles", state = "California", country = "United States" }))
  end)

  it("uses country alone when it is the only level", function()
    assert.equals("United States", collection_name.auto({ country = "United States" }))
  end)

  it("returns nil when no level is present", function()
    assert.is_nil(collection_name.auto({}))
  end)

  it("treats empty-string fields as absent", function()
    assert.equals("Paris, France", collection_name.auto({
      poi = "", city = "Paris", state = "", country = "France" }))
  end)
end)

describe("collection_name.of", function()
  local place = {
    poi = "Venice Beach", city = "Los Angeles",
    state = "California", country = "United States",
  }

  it("applies primary + secondary", function()
    assert.equals("Los Angeles, California",
      collection_name.of(place, { primary = "city", secondary = "state" }))
  end)

  it("omits the secondary when it is none", function()
    assert.equals("Los Angeles",
      collection_name.of(place, { primary = "city", secondary = "none" }))
  end)

  it("omits the secondary when it equals the primary", function()
    assert.equals("Los Angeles",
      collection_name.of(place, { primary = "city", secondary = "city" }))
  end)

  it("falls back to auto when the primary level is absent", function()
    local p = { city = "Los Angeles", state = "California" }
    assert.equals("Los Angeles, California",
      collection_name.of(p, { primary = "poi", secondary = "city" }))
  end)

  it("omits the secondary when it is absent for this photo", function()
    local p = { city = "Los Angeles" }
    assert.equals("Los Angeles",
      collection_name.of(p, { primary = "city", secondary = "state" }))
  end)
end)

describe("collection_name.format_error", function()
  it("accepts a broader secondary", function()
    assert.is_nil(collection_name.format_error("poi", "city"))
    assert.is_nil(collection_name.format_error("city", "country"))
  end)

  it("accepts a none secondary", function()
    assert.is_nil(collection_name.format_error("country", "none"))
  end)

  it("rejects a secondary that is not broader than the primary", function()
    assert.is_string(collection_name.format_error("city", "poi"))
    assert.is_string(collection_name.format_error("city", "city"))
  end)

  it("rejects an unknown level", function()
    assert.is_string(collection_name.format_error("borough", "city"))
  end)
end)
