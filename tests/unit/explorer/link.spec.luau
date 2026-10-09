--!strict
local Link = require("../../../plugin/lib/explorer/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function grant(): Link.Grant
	return {
		project = "billing",
		root = "/repo/sdf/billing",
		path = "src/FileCabinet/SuiteScripts/b.js",
		fileCabinetPath = "/SuiteScripts/b.js",
		authId = "demo-sb",
		label = "1234567_SB1",
		accountId = "1234567_SB1",
		production = false,
		exp = 0,
	}
end

describe("explorer upload links", function()
	local id = Link.newId("seed", 1)

	it("carry only a random grant id, so a link printed elsewhere cannot name a file to upload", function()
		local url = Link.uploadUrl(id)
		expect(url).toBe("tern-netsuite://explorer/upload?grant=" .. id)
		expect((string.find(url, "SuiteScripts", 1, true))).toBeNil()
		local action, parsed = Link.parse(url)
		expect(action).toBe("upload")
		expect(parsed).toBe(id)
	end)

	it("reject anything that is not exactly an upload link with a well-formed id", function()
		for _, url in
			{
				"tern-netsuite://explorer/upload?grant=xyz",
				"tern-netsuite://explorer/upload?grant=" .. id .. "&path=/x",
				"tern-netsuite://explorer/run?grant=" .. id,
				"tern-netsuite://ns/upload?grant=" .. id,
			}
		do
			local action = Link.parse(url)
			expect(action).toBeNil()
		end
	end)

	it("make distinct ids per request", function()
		expect(Link.newId("seed", 1) ~= Link.newId("seed", 2)).toBe(true)
		expect(Link.validId(id)).toBe(true)
	end)
end)

describe("upload grants", function()
	it("can be used once, so a replayed link does nothing", function()
		local grants = Link.addGrant(nil, "a1", grant(), 100)
		local g, rest = Link.takeGrant(grants, "a1", 101)
		assert(g, "grant")
		expect(g.fileCabinetPath).toBe("/SuiteScripts/b.js")
		local again, _, why = Link.takeGrant(rest, "a1", 102)
		expect(again).toBeNil()
		expect(why).toContain("already used or unknown")
	end)

	it("expire, so a stale click long after the key press does nothing", function()
		local grants = Link.addGrant({}, "a1", grant(), 100)
		local g, _, why = Link.takeGrant(grants, "a1", 100 + Link.TTL_SECONDS + 1)
		expect(g).toBeNil()
		expect(why).toContain("expired")
	end)

	it("drop expired entries and stay bounded", function()
		local grants: any = {}
		for i = 1, Link.MAX_GRANTS + 5 do
			grants = Link.addGrant(grants, "g" .. i, grant(), i)
		end
		local n = 0
		for _ in grants do
			n += 1
		end
		expect(n).toBe(Link.MAX_GRANTS)
		local later = Link.addGrant(grants, "late", grant(), 10000)
		local m = 0
		for _ in later do
			m += 1
		end
		expect(m).toBe(1)
	end)

	it("refuse a malformed stored value instead of uploading something half-specified", function()
		local bad: any = { a1 = { root = "/r", exp = 1000 } }
		local g, _, why = Link.takeGrant(bad, "a1", 1)
		expect(g).toBeNil()
		expect(why).toContain("malformed")
	end)
end)

return nil
