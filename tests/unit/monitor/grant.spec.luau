--!strict
local Encoding = require("../../../plugin/lib/ns/encoding")
local Grant = require("../../../plugin/lib/monitor/grant")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("single-use link grants", function()
	it("hands the stored request to the first taker only, so a replayed link starts nothing", function()
		local stored = Grant.add(nil, "aaaa", { "x" }, 100)
		local data, rest = Grant.take(stored, "aaaa", 101)
		expect(data).toEqual({ "x" })
		local again, _, why = Grant.take(rest, "aaaa", 102)
		expect(again).toBeNil()
		expect(why).toBe("unknown")
	end)

	it("survives the JSON round trip of tern.kv", function()
		local stored = json.decode(Encoding.json(Grant.add(nil, "aaaa", true, 100)))
		expect((Grant.take(stored, "aaaa", 101))).toBe(true)
	end)

	it("refuses expired grants and drops them from the store", function()
		local stored = Grant.add(nil, "aaaa", true, 100)
		stored = Grant.add(stored, "bbbb", true, 100 + Grant.TTL_SECONDS)
		local data, rest, why = Grant.take(stored, "aaaa", 101 + Grant.TTL_SECONDS)
		expect(data).toBeNil()
		expect(why).toBe("expired")
		expect(rest.aaaa).toBeNil()
		expect(rest.bbbb ~= nil).toBe(true)
	end)

	it("keeps at most MAX_GRANTS so repeated clicks cannot grow the store", function()
		local stored: any = nil
		for i = 1, Grant.MAX_GRANTS + 5 do
			stored = Grant.add(stored, string.format("%04d", i), true, i)
		end
		local n = 0
		for _ in stored do
			n += 1
		end
		expect(n).toBe(Grant.MAX_GRANTS)
		expect(stored["0001"]).toBeNil()
	end)

	it("makes ids a link cannot guess from the counter alone", function()
		local a = Grant.newId("logs", "seed-a", 1)
		expect(Grant.validId(a)).toBe(true)
		expect(a ~= Grant.newId("logs", "seed-b", 1)).toBe(true)
		expect(Grant.validId("xyz")).toBe(false)
	end)
end)

return nil
