--!strict
local Grant = require("../../../plugin/lib/monitor/grant")
local Link = require("../../../plugin/lib/inspector/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local HOLD = Link.HOLD_ARG

local function decision(url: string): Link.Decision
	local d, err = Link.route(url)
	if d == nil then
		error("rejected: " .. tostring(err))
	end
	return d
end

local function rejected(url: string): string
	local d, err = Link.route(url)
	expect(d).toBeNil()
	return err or ""
end

describe("inspect links", function()
	it("opens the inspector held until Enter, because any program can print such a link", function()
		local d = decision("tern-netsuite://inspect?connection=sb-rest&type=SalesOrder&id=123")
		expect(d.block).toBe("tern-netsuite.inspect")
		expect(d.hold).toBe(true)
		expect(Link.blockArgs(d)).toEqual({ "connection=sb-rest", "type=salesorder", "id=123", HOLD })
		expect(decision("tern-netsuite://inspect").args).toEqual({})
	end)

	it("lets a console row link with an id but no type: the block then asks for the type", function()
		expect(decision("tern-netsuite://inspect?id=77").args).toEqual({ "id=77" })
	end)

	it("takes a pasted NetSuite URL as ref, keeping its account to pick the connection", function()
		local url = "tern-netsuite://inspect?ref="
			.. "https%3A%2F%2F1234567-sb1.app.netsuite.com%2Fapp%2Fcommon%2Fcustom%2Fcustrecordentry.nl%3Frectype%3D12%26id%3D5"
		expect(decision(url).args).toEqual({ "rectype=12", "id=5", "account=1234567_SB1" })
		expect(decision("tern-netsuite://inspect?ref=customer%3A42").args).toEqual({ "type=customer", "id=42" })
	end)

	it("refuses anything it cannot validate instead of passing it on", function()
		expect(rejected("tern-netsuite://inspect?type=salesorder")).toContain("needs id")
		expect(rejected("tern-netsuite://inspect?type=widget&id=1")).toContain("unknown record type")
		expect(rejected("tern-netsuite://inspect?id=1&id=2")).toContain("more than once")
		expect(rejected("tern-netsuite://inspect?id=1;drop")).toContain("invalid id")
		expect(rejected("tern-netsuite://inspect?account=1234567&id=1")).toContain("unknown parameter")
		expect(rejected("tern-netsuite://inspect?ref=so%3A1&id=1")).toContain("cannot be combined")
		expect(rejected("tern-netsuite://inspect?type=so&rectype=3&id=1")).toContain("not both")
		expect(rejected("tern-netsuite://inspect?id=%zz")).toContain("malformed escape")
		expect(rejected("tern-netsuite://inspect/other")).toContain("unknown inspect link path")
		expect(rejected("tern-netsuite://inspect?id=1#x")).toContain("fragment")
		expect(rejected("tern-netsuite://inspect?connection=Bad%20Id&id=1")).toContain("invalid connection")
	end)

	it("builds a link other features can print, which routes back to the same block args", function()
		local url = Link.url({ connection = "sb-rest", type = "invoice", id = "9" })
		expect(url).toBe("tern-netsuite://inspect?connection=sb-rest&type=invoice&id=9")
		expect(decision(url).args).toEqual({ "connection=sb-rest", "type=invoice", "id=9" })
	end)

	it("starts at once only through a single-use grant the plugin stored", function()
		local id = Link.newId("seed", 1)
		local start, grants = Link.grantStart(Link.url({ type = "customer", id = "42" }), nil, id, 1000)
		expect(start).toBe("tern-netsuite://inspect/start?grant=" .. id)
		local d = decision(start :: string)
		expect(d.grant).toBe(id)
		local args, rest = Link.takeStart(grants, id, 1001)
		expect(args).toEqual({ "type=customer", "id=42" })
		local again, _, why = Link.takeStart(rest, id, 1002)
		expect(again).toBeNil()
		expect(why).toContain("already used")
		local _, _, late = Link.takeStart(grants, id, 1000 + Grant.TTL_SECONDS + 1)
		expect(late).toContain("expired")
	end)

	it("does not grant a start for something that is not a plain inspect link", function()
		local start, grants, why = Link.grantStart("tern-netsuite://logs", nil, Link.newId("s", 2), 1)
		expect(start).toBeNil()
		expect(grants).toBeNil()
		expect(why).toContain("not a tern-netsuite://inspect link")
	end)

	it("drops invalid block args and names them", function()
		local launch, problems = Link.fromArgs({ "type=salesorder", "bogus", "id=x" })
		expect(launch.type).toBeNil()
		expect(#problems).toBe(3)
	end)
end)

return nil
