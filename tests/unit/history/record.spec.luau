--!strict
local Record = require("../../../plugin/lib/history/record")
local Recognize = require("../../../plugin/lib/history/recognize")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local HEAD = "74fbe1735dfd1db4fe1faf64bcf5e28849817553"

local function input(line: string, extra: { [string]: any }?): Record.Input
	local m = Recognize.line(line, { cwd = "/work/sdf/billing" }) :: Recognize.Match
	local i: { [string]: any } = {
		finishedAt = 1791476800,
		tookMs = 42500,
		status = 0,
		line = line,
		cwd = "/work/sdf/billing",
		match = m,
		context = { projectRoot = "/work/sdf/billing", projectName = "billing", authId = "demo-sb" },
		resolution = {
			authId = "demo-sb",
			source = "cli",
			accountId = "1234567_SB1",
			production = false,
			label = "1234567_SB1",
		},
		git = { root = "/work", branch = "develop", head = HEAD, dirty = false },
	}
	for k, v in (extra or {}) :: { [string]: any } do
		i[k] = v
	end
	return i :: any
end

describe("a deploy record", function()
	it("captures where, what, against which account and from which commit a deploy ran", function()
		local r = Record.build(input("suitecloud project:deploy --log logs/d.log"))
		expect(r.at).toBe(1791476800)
		expect(r.startedAt).toBe(1791476757)
		expect(r.command).toBe("project:deploy")
		expect(r.project).toBe("billing")
		expect(r.root).toBe("/work/sdf/billing")
		expect(r.authId).toBe("demo-sb")
		expect(r.accountId).toBe("1234567_SB1")
		expect(r.production).toBe(false)
		expect(r.branch).toBe("develop")
		expect(r.head).toBe(HEAD)
		expect(r.dirty).toBe(false)
		expect(r.log).toBe("/work/sdf/billing/logs/d.log")
	end)

	it("is still written when git answered only partly or not at all", function()
		local partial = Record.build(input("suitecloud project:deploy", { git = { branch = "develop" } }))
		expect(partial.branch).toBe("develop")
		expect(partial.head).toBeNil()
		expect(partial.dirty).toBeNil()
		local noGit: any = input("suitecloud project:deploy")
		noGit.git = nil
		local none = Record.build(noGit)
		expect(none.branch).toBeNil()
		expect(none.command).toBe("project:deploy")
	end)

	it("says the account is unknown instead of guessing when the auth id could not be resolved", function()
		local r = Record.build(input("suitecloud project:deploy", {
			resolution = { authId = "demo-sb", source = "unknown", production = true, label = "demo-sb" },
		}))
		expect(r.authId).toBe("demo-sb")
		expect(r.accountSource).toBe("unknown")
		expect(r.accountId).toBeNil()
		expect(r.production).toBeNil()
	end)

	it("follows the account the project pointed at when the deploy finished", function()
		local r = Record.build(input("suitecloud project:deploy", {
			context = { projectRoot = "/work/sdf/billing", projectName = "billing", authId = "prod" },
			resolution = {
				authId = "prod",
				source = "configured",
				accountId = "1234567",
				production = true,
				label = "PROD",
			},
		}))
		expect(r.authId).toBe("prod")
		expect(r.accountLabel).toBe("PROD")
		expect(r.production).toBe(true)
	end)

	it("caps a pasted giant command line so one entry cannot bloat the history", function()
		local long = "suitecloud file:upload --paths " .. string.rep("/SuiteScripts/x.js ", 400)
		local r = Record.build(input(long))
		expect(#r.line <= Record.MAX_LINE).toBe(true)
		expect(string.sub(r.line, -3)).toBe("…")
	end)

	it("never writes environment assignment values to disk, since they are often tokens", function()
		local r = Record.build(input("NS_TOKEN=s3cr3t DEBUG='a b' suitecloud project:deploy && FOO=bar echo done"))
		expect((string.find(r.line, "s3cr3t", 1, true))).toBeNil()
		expect((string.find(r.line, "a b", 1, true))).toBeNil()
		expect((string.find(r.line, "bar", 1, true))).toBeNil()
		expect(r.line).toBe("NS_TOKEN=… DEBUG=… suitecloud project:deploy && FOO=… echo done")
	end)

	it("round-trips through one JSON line", function()
		local r = Record.build(input("suitecloud project:deploy --log logs/d.log"))
		local line = Record.encode(r)
		expect(string.sub(line, -1)).toBe("\n")
		expect(select(2, string.gsub(line, "\n", ""))).toBe(1)
		expect(Record.decode(line, json.decode)).toEqual(r)
	end)

	it("skips lines that are not records (a torn write, another version)", function()
		expect(Record.decode('{"v":1,"at":', json.decode)).toBeNil()
		expect(Record.decode('{"v":2,"at":1,"cwd":"/","command":"project:deploy"}', json.decode)).toBeNil()
		expect(Record.decode("[]", json.decode)).toBeNil()
	end)
end)

return nil
