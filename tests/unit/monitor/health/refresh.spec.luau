--!strict
local Refresh = require("../../../../plugin/lib/monitor/health/refresh")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local ID = string.rep("c0", 16)

describe("the health refresh link", function()
	it("polls only for a grant the health block stored, once", function()
		local action, id = Refresh.parse(Refresh.url(ID))
		expect(action).toBe("refresh")
		expect(id).toBe(ID)
		local ok, rest = Refresh.take(Refresh.add(nil, ID, 100), ID, 101)
		expect(ok).toBe(true)
		expect((Refresh.take(rest, ID, 102))).toBe(false)
	end)

	it("recognises a bare or forged refresh link so the window can ignore it quietly", function()
		local action, id = Refresh.parse("tern-netsuite://health/refresh")
		expect(action).toBe("refresh")
		expect(id).toBeNil()
		expect(select(2, Refresh.parse("tern-netsuite://health/refresh?grant=zz"))).toBeNil()
		expect((Refresh.take(nil, ID, 100))).toBe(false)
		expect((Refresh.parse("tern-netsuite://health/other"))).toBeNil()
	end)

	it("spaces refreshes apart so repeated presses do not hammer NetSuite", function()
		expect(Refresh.allowed(nil, 100)).toBe(true)
		expect(Refresh.allowed(100, 100 + Refresh.MIN_SECONDS - 1)).toBe(false)
		expect(Refresh.allowed(100, 100 + Refresh.MIN_SECONDS)).toBe(true)
		-- A clock that went back must not block refreshes forever.
		expect(Refresh.allowed(100, 50)).toBe(true)
	end)
end)

return nil
