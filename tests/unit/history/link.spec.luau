--!strict
local Link = require("../../../plugin/lib/history/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("history links", function()
	it("carry a failed run's repository and id to the window, which opens its log", function()
		local url = Link.failedLog("example-org/example-repo", 1000000102)
		expect(url).toBe("tern-netsuite://history/failed-log?repo=example-org%2Fexample-repo&run=1000000102")
		expect(Link.parse(url)).toEqual({ kind = "failed-log", repo = "example-org/example-repo", run = 1000000102 })
	end)

	it("refuse anything that could smuggle shell text into the log command", function()
		expect(Link.parse("tern-netsuite://history/failed-log?repo=a%2Fb%3Brm&run=1")).toBeNil()
		expect(Link.parse("tern-netsuite://history/failed-log?repo=a%2Fb&run=1%3Bx")).toBeNil()
		expect(Link.parse("tern-netsuite://history/failed-log?repo=a%2Fb")).toBeNil()
		expect(Link.parse("tern-netsuite://history/other?repo=a%2Fb&run=1")).toBeNil()
		expect(Link.parse("tern-netsuite://ns/failed-log?repo=a%2Fb&run=1")).toBeNil()
	end)
end)

return nil
