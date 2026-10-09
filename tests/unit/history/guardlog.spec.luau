--!strict
local Audit = require("../../../plugin/lib/guard/audit")
local GuardLog = require("../../../plugin/lib/history/guardlog")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local HEAD = "74fbe1735dfd1db4fe1faf64bcf5e28849817553"

local function event(decision: Audit.Decision, at: number, extra: { [string]: any }?): Audit.Event
	local e: { [string]: any } = {
		decision = decision,
		decidedAt = at,
		command = "project:deploy",
		argv = { "suitecloud", "project:deploy", "--log", "d.log" },
		cwd = "/private/tmp/work/billing",
		folder = "/private/tmp/work/billing/src",
		authId = "prod",
		accountId = "1234567",
		accountLabel = "PROD",
		production = true,
		fingerprint = string.rep("ab", 32),
		files = 3,
		branch = "main",
		head = HEAD,
		dirty = false,
	}
	for k, v in (extra or {}) :: { [string]: any } do
		e[k] = v
	end
	return e :: any
end

describe("guard decisions from audit.log", function()
	it("reads every decision the approve block wrote, newest last", function()
		local unknown: any = event("cancelled", 300, { accountLabel = "unknown" })
		unknown.accountId, unknown.authId = nil, nil
		local text = Audit.line(event("approved", 100))
			.. Audit.line(event("denied", 200, { reason = "fingerprint mismatch" }))
			.. Audit.line(unknown)
		local entries = GuardLog.parse(text, json.decode)
		expect(#entries).toBe(3)
		local a = entries[1]
		expect(a.decision).toBe("approved")
		expect(a.at).toBe(100)
		expect(a.command).toBe("project:deploy")
		expect(a.accountId).toBe("1234567")
		expect(a.accountLabel).toBe("PROD")
		expect(a.production).toBe(true)
		expect(a.cwd).toBe("/private/tmp/work/billing")
		expect(a.line).toBe("suitecloud project:deploy --log d.log")
		expect(a.branch).toBe("main")
		expect(a.head).toBe(HEAD)
		expect(entries[2].reason).toBe("fingerprint mismatch")
		expect(entries[3].accountId).toBeNil()
	end)

	it("quotes argv words with spaces when it shows the command", function()
		local text =
			Audit.line(event("approved", 1, { argv = { "suitecloud", "project:deploy", "--log", "my logs/d.log" } }))
		expect(GuardLog.parse(text, json.decode)[1].line).toBe("suitecloud project:deploy --log 'my logs/d.log'")
	end)

	it("skips lines it cannot read rather than hiding the whole log", function()
		local text = "garbage\n" .. Audit.line(event("approved", 5)) .. '{"v":1,"decision":"maybe"}\n'
		local entries = GuardLog.parse(text, json.decode)
		expect(#entries).toBe(1)
		expect(entries[1].at).toBe(5)
	end)
end)

return nil
