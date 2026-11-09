--!strict
local Link = require("../../../plugin/lib/history/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local ID = Link.newId("seed", 1)

describe("history links", function()
	it("carry only a grant id; the repository and run stay in the plugin's kv", function()
		local url = Link.failedLogUrl(ID)
		expect(url).toBe("tern-netsuite://history/failed-log?grant=" .. ID)
		expect(Link.parse(url)).toBe(ID)
		expect(Link.newId("seed", 2) ~= ID).toBe(true)
	end)

	it("refuse bare links that name a repository themselves", function()
		expect(Link.parse("tern-netsuite://history/failed-log?repo=example-org%2Fexample-repo&run=1")).toBeNil()
		expect(Link.parse("tern-netsuite://history/failed-log?grant=short")).toBeNil()
		expect(Link.parse("tern-netsuite://history/failed-log?grant=" .. ID .. "&repo=a%2Fb")).toBeNil()
		expect(Link.parse("tern-netsuite://ns/failed-log?grant=" .. ID)).toBeNil()
	end)

	it("hand a grant out once, and only before it expires", function()
		local stored = Link.addGrant(nil, ID, "example-org/example-repo", 1000000102, 100)
		local g, rest, why = Link.takeGrant(stored, ID, 150)
		expect(why).toBeNil()
		expect(g).toEqual({ repo = "example-org/example-repo", run = 1000000102, exp = 100 + Link.TTL_SECONDS })
		local again, _, used = Link.takeGrant(rest, ID, 151)
		expect(again).toBeNil()
		expect(used ~= nil).toBe(true)
		local late, _, expired = Link.takeGrant(stored, ID, 100 + Link.TTL_SECONDS + 1)
		expect(late).toBeNil()
		expect(expired ~= nil).toBe(true)
	end)

	it("refuse stored grants that could smuggle shell text into the log command", function()
		local bad = { [ID] = { repo = "a/b;rm", run = 1, exp = 200 } }
		expect((Link.takeGrant(bad, ID, 100))).toBeNil()
		local frac = { [ID] = { repo = "a/b", run = 1.5, exp = 200 } }
		expect((Link.takeGrant(frac, ID, 100))).toBeNil()
	end)

	it("keep at most MAX_GRANTS, dropping the oldest", function()
		local stored: any = nil
		for i = 1, Link.MAX_GRANTS + 5 do
			stored = Link.addGrant(stored, Link.newId("s", i), "a/b", i, i)
		end
		local n = 0
		for _ in stored do
			n += 1
		end
		expect(n).toBe(Link.MAX_GRANTS)
		expect(stored[Link.newId("s", 1)]).toBeNil()
	end)
end)

return nil
