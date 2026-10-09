--!strict
local Link = require("../../../../plugin/lib/monitor/logs/link")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function decision(url: string): any
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

describe("execution log links", function()
	it("opens the logs block with no filters", function()
		expect(decision("tern-netsuite://logs")).toEqual({ block = "tern-netsuite.logs", args = {} })
		expect(decision("tern-netsuite://logs/")).toEqual({ block = "tern-netsuite.logs", args = {} })
		expect(decision("tern-netsuite://logs?")).toEqual({ block = "tern-netsuite.logs", args = {} })
	end)

	it("passes a connection, scripts and a start time as validated block arguments", function()
		local d = decision(
			"tern-netsuite://logs?connection=sandbox-restlet&script=customscript_a,CUSTOMSCRIPT_B&script=123&since=2026-10-08T22:00"
		)
		expect(d.block).toBe("tern-netsuite.logs")
		expect(d.args).toEqual({
			"connection=sandbox-restlet",
			"script=customscript_a",
			"script=customscript_b",
			"script=123",
			"since=2026-10-08 22:00:00",
		})
	end)

	it("accepts percent-encoded and form-encoded values", function()
		local d = decision("tern-netsuite://logs?since=2026-10-08%2022%3A00%3A05&script=customscript%5Fa")
		expect(d.args).toEqual({ "script=customscript_a", "since=2026-10-08 22:00:05" })
		expect(decision("tern-netsuite://logs?since=2026-10-08+22:00").args).toEqual({ "since=2026-10-08 22:00:00" })
	end)

	it("accepts a relative start in minutes, hours or days", function()
		expect(decision("tern-netsuite://logs?since=15m").args).toEqual({ "since=15m" })
		expect(decision("tern-netsuite://logs?since=2h").args).toEqual({ "since=120m" })
		expect(decision("tern-netsuite://logs?since=1d").args).toEqual({ "since=1440m" })
	end)

	it("rejects SQL injection attempts in every parameter", function()
		expect(rejected("tern-netsuite://logs?script=customscript_a'%20OR%201=1--")).toContain("script")
		expect(rejected("tern-netsuite://logs?script=customscript_a)%20UNION%20SELECT")).toContain("script")
		expect(rejected("tern-netsuite://logs?script=1;DROP")).toContain("script")
		expect(rejected("tern-netsuite://logs?since=2026-10-08'%20OR%20'1'='1")).toContain("since")
		expect(rejected("tern-netsuite://logs?connection=x';--")).toContain("connection")
	end)

	it("rejects unknown parameters, fragments, extra paths and duplicate single values", function()
		expect(rejected("tern-netsuite://logs?sql=SELECT%201")).toContain("sql")
		expect(rejected("tern-netsuite://logs?connection=a#frag")).toContain("fragment")
		expect(rejected("tern-netsuite://logs/other?connection=a")).toContain("path")
		expect(rejected("tern-netsuite://logs?connection=a&connection=b")).toContain("connection")
		expect(rejected("tern-netsuite://ns/query?id=abc")).toContain("logs")
	end)

	it("rejects impossible dates, bad relative spans and malformed escapes", function()
		expect(rejected("tern-netsuite://logs?since=2026-13-01")).toContain("since")
		expect(rejected("tern-netsuite://logs?since=2026-02-30")).toContain("since")
		expect(rejected("tern-netsuite://logs?since=2026-10-08T25:00")).toContain("since")
		expect(rejected("tern-netsuite://logs?since=0m")).toContain("since")
		expect(rejected("tern-netsuite://logs?since=99999d")).toContain("since")
		expect(rejected("tern-netsuite://logs?script=%zz")).toContain("escape")
		expect(rejected("tern-netsuite://logs?script=customscript_a%00")).toContain("script")
	end)

	it("caps the number of scripts and the URL length", function()
		local many = {}
		for i = 1, Link.MAX_SCRIPTS + 1 do
			table.insert(many, "customscript_" .. i)
		end
		expect(rejected("tern-netsuite://logs?script=" .. table.concat(many, ","))).toContain("scripts")
		expect(rejected("tern-netsuite://logs?script=" .. string.rep("a", Link.MAX_URL))).toContain("long")
	end)

	it("hands the connect link to the connect block so a missing credential is one click away", function()
		expect(decision("tern-netsuite://logs/connect?connection=sandbox-restlet")).toEqual({
			block = "tern-netsuite.connect",
			args = { "sandbox-restlet" },
		})
		expect(rejected("tern-netsuite://logs/connect")).toContain("connection")
		expect(rejected("tern-netsuite://logs/connect?connection=a&script=customscript_a")).toContain("script")
	end)

	it("builds links other features can hand out, and they round-trip", function()
		local url = Link.url({ connection = "sb", scripts = { "customscript_a", "42" }, since = { minutes = 30 } })
		expect(url).toBe("tern-netsuite://logs?connection=sb&script=customscript_a&script=42&since=30m")
		expect(decision(url).args).toEqual({ "connection=sb", "script=customscript_a", "script=42", "since=30m" })
		expect(Link.connectUrl("sb")).toBe("tern-netsuite://logs/connect?connection=sb")
	end)

	it("re-validates block arguments, keeping the good ones and naming the bad ones", function()
		local launch, problems =
			Link.fromArgs({ "connection=sb", "script=customscript_a", "script=x'y", "since=bogus", "z" })
		expect(launch.connection).toBe("sb")
		expect(launch.scripts).toEqual({ "customscript_a" })
		expect(launch.since).toBeNil()
		expect(#problems).toBe(3)
		local ok = Link.fromArgs(Link.toArgs({ scripts = { "7" }, since = { at = "2026-10-08 22:00:00" } }))
		expect(ok.scripts).toEqual({ "7" })
		expect(ok.since).toEqual({ at = "2026-10-08 22:00:00" })
	end)
end)

return nil
