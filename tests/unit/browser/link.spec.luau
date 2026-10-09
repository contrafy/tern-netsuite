--!strict
local Imports = require("../../../plugin/lib/browser/imports")
local Link = require("../../../plugin/lib/browser/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local REQ: Imports.Request = {
	kind = "object",
	root = "/work/proj/demo",
	projectFolder = "src",
	type = "restlet",
	scriptId = "customscript_demo_90",
	destinationFolder = "/Objects",
	excludeFiles = false,
}

local ID = string.rep("ab", 16)

describe("browser links", function()
	it("opens the browser for a directory, surviving spaces and reserved characters", function()
		local url = Link.browseUrl("/work/my proj/a&b#c")
		expect(url).toBe("tern-netsuite://browser?cwd=%2Fwork%2Fmy%20proj%2Fa%26b%23c")
		local l = Link.parse(url) :: Link.Parsed
		expect(l.t).toBe("browse")
		expect(l.cwd).toBe("/work/my proj/a&b#c")
	end)

	it("opens the browser without a directory, letting the block use its pane's", function()
		local l = Link.parse("tern-netsuite://browser") :: Link.Parsed
		expect(l.t).toBe("browse")
		expect(l.cwd).toBeNil()
	end)

	it("never accepts a relative directory", function()
		expect(Link.parse("tern-netsuite://browser?cwd=work")).toBeNil()
	end)

	it("carries only a grant id for imports, so printed links cannot name what to import", function()
		local url = Link.importUrl(ID)
		expect(url).toBe("tern-netsuite://browser/import?grant=" .. ID)
		local l = Link.parse(url) :: Link.Parsed
		expect(l.t).toBe("import")
		expect(l.id).toBe(ID)
		expect(Link.parse("tern-netsuite://browser/import?grant=XYZ")).toBeNil()
		expect(Link.parse("tern-netsuite://browser/import?scriptid=x")).toBeNil()
	end)
end)

describe("import grants", function()
	it("hands a stored import over exactly once", function()
		local stored = Link.addGrant(nil, ID, { request = REQ, label = "demo -> 1234567_SB1", exp = 0 }, 1000)
		local g, rest, why = Link.takeGrant(stored, ID, 1010)
		expect(why).toBeNil()
		expect((g :: Link.Grant).request).toEqual(REQ)
		local again, _, why2 = Link.takeGrant(rest, ID, 1010)
		expect(again).toBeNil()
		expect(why2).toContain("already used")
	end)

	it("expires grants so a stale link cannot start an import later", function()
		local stored = Link.addGrant(nil, ID, { request = REQ, label = "x", exp = 0 }, 1000)
		local g, _, why = Link.takeGrant(stored, ID, 1000 + Link.TTL_SECONDS + 1)
		expect(g).toBeNil()
		expect(why).toContain("expired")
	end)

	it("rejects a stored request that no longer validates (the store is a shared JSON file)", function()
		local bad = table.clone(REQ)
		bad.scriptId = "--excludefiles"
		local stored = Link.addGrant(nil, ID, { request = bad, label = "x", exp = 0 }, 1000)
		local g, _, why = Link.takeGrant(stored, ID, 1000)
		expect(g).toBeNil()
		expect(why).toContain("script ID")
	end)

	it("keeps the store bounded", function()
		local stored: any = nil
		for i = 1, Link.MAX_GRANTS + 5 do
			stored = Link.addGrant(stored, string.format("%032x", i), { request = REQ, label = "x", exp = 0 }, 1000 + i)
		end
		local n = 0
		for _ in stored do
			n += 1
		end
		expect(n).toBe(Link.MAX_GRANTS)
	end)

	it("derives distinct hex ids from a per-VM seed and a counter", function()
		local a, b = Link.newId("seed", 1), Link.newId("seed", 2)
		expect(#a).toBe(32)
		expect(a ~= b).toBe(true)
		expect(string.find(a, "^[0-9a-f]+$") ~= nil).toBe(true)
	end)
end)

return nil
