--!strict
local Link = require("../../../plugin/lib/console/link")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("console links", function()
	it("opens a console with a .sql file loaded, from the clicked pane's folder", function()
		local d =
			Link.route("tern-netsuite://console?connection=sb-rest&file=%2Ftmp%2Facme%2Fopen%20orders.sql", "/tmp/acme")
		expect(d).toEqual({
			block = "tern-netsuite.console",
			args = { "cwd=/tmp/acme", "connection=sb-rest", "file=/tmp/acme/open orders.sql" },
		})
	end)

	it("never lets a link run a query or load a saved query: any program can print one", function()
		local _, why = Link.route("tern-netsuite://console?file=/tmp/a.sql&run=1")
		expect(why).toBe('unknown parameter "run"')
		_, why = Link.route("tern-netsuite://console?saved=x")
		expect(why).toBe('unknown parameter "saved"')
	end)

	it("loads only .sql files given by absolute path", function()
		local _, why = Link.route("tern-netsuite://console?file=/Users/demo/.ssh/id_ed25519")
		expect(why).toContain("absolute path to a .sql file")
		_, why = Link.route("tern-netsuite://console?file=queries/a.sql")
		expect(why).toContain("absolute path to a .sql file")
	end)

	it("refuses malformed links rather than guessing", function()
		expect(select(2, Link.route("tern-netsuite://console/run"))).toContain("unknown console link path")
		expect(select(2, Link.route("tern-netsuite://console?connection=a&connection=b"))).toContain("more than once")
		expect(select(2, Link.route("tern-netsuite://console?connection=%zz"))).toContain("malformed escape")
		expect(select(2, Link.route("tern-netsuite://console#x"))).toBe("a console link takes no fragment")
	end)

	it("reads the palette's block args back, naming the ones it drops", function()
		local launch, problems = Link.fromArgs({ "cwd=/tmp/acme", "file=/tmp/acme/a.sql", "run=1", "saved=x", "bogus" })
		expect(launch).toEqual({ cwd = "/tmp/acme", file = "/tmp/acme/a.sql", run = true })
		expect(problems).toEqual({ 'unknown argument "bogus"', "file and saved are both given; the file is loaded" })
		expect(Link.toArgs(launch)).toEqual({ "cwd=/tmp/acme", "file=/tmp/acme/a.sql", "run=1" })
	end)
end)

return nil
