--!strict
local Audit = require("../../../plugin/lib/guard/audit")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local EVENT: Audit.Event = {
	decision = "approved",
	decidedAt = 1791476710,
	command = "project:deploy",
	argv = { "suitecloud", "project:deploy", "--log", 'x "y"' },
	cwd = "/work/sdf/billing",
	folder = "/work/sdf/billing/src",
	authId = "prod",
	accountId = "1234567",
	accountLabel = "PROD",
	production = true,
	fingerprint = string.rep("ab", 32),
	files = 42,
	branch = "main",
	head = string.rep("1", 40),
	dirty = false,
}

describe("the audit log line", function()
	it("is one JSON object per line that records who approved what against which account", function()
		local line = Audit.line(EVENT)
		expect(string.sub(line, -1)).toBe("\n")
		expect(select(2, string.gsub(line, "\n", ""))).toBe(1)
		local doc = json.decode(line)
		expect(doc.v).toBe(1)
		expect(doc.decision).toBe("approved")
		expect(doc.account_id).toBe("1234567")
		expect(doc.account_label).toBe("PROD")
		expect(doc.production).toBe(true)
		expect(doc.argv).toEqual({ "suitecloud", "project:deploy", "--log", 'x "y"' })
		expect(doc.files).toBe(42)
		expect(doc.dirty).toBe(false)
	end)

	it("omits what is unknown instead of inventing it", function()
		local e = table.clone(EVENT)
		e.accountId = nil
		e.authId = nil
		e.branch = nil
		e.head = nil
		e.dirty = nil
		local doc = json.decode(Audit.line(e))
		expect(doc.account_id).toBeNil()
		expect(doc.auth_id).toBeNil()
		expect(doc.branch).toBeNil()
	end)

	it("keeps a deny reason with control characters on the same line", function()
		local e = table.clone(EVENT)
		e.decision = "denied"
		e.reason = "line one\nline two"
		local line = Audit.line(e)
		expect(select(2, string.gsub(line, "\n", ""))).toBe(1)
		expect(json.decode(line).reason).toBe("line one\nline two")
	end)
end)

return nil
