--!strict
local Link = require("../../../plugin/lib/drift/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("drift link", function()
	it("opens a printed link held, so no program can make the plugin run the CLI", function()
		local p = Link.parse(Link.url("/work/acme/billing app"))
		expect(p and p.cwd).toBe("/work/acme/billing app")
		local cwd, held = Link.fromArgs(Link.blockArgs(p and p.cwd, true))
		expect(cwd).toBe("/work/acme/billing app")
		expect(held).toBe(true)
		expect(Link.parse("tern-netsuite://drift")).toEqual({ cwd = nil })
	end)

	it("refuses links with relative directories, control characters or anything else", function()
		expect(Link.parse("tern-netsuite://drift?cwd=work")).toBeNil()
		expect(Link.parse("tern-netsuite://drift?cwd=%2Fa%0Ab")).toBeNil()
		expect(Link.parse("tern-netsuite://drift/run?authid=demo-prod")).toBeNil()
		expect(Link.parse("tern-netsuite://drift?cwd=/a&run=1")).toBeNil()
	end)
end)

return nil
