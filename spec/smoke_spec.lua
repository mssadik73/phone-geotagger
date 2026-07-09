describe("test harness", function()
  it("loads the vendored dkjson from the plugin directory", function()
    local dkjson = require "dkjson"
    local doc = dkjson.decode('{"answer": 42}')
    assert.equals(42, doc.answer)
  end)
end)
