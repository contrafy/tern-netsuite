--!strict
local Config = require("../../../plugin/lib/config")
local Context = require("../../../plugin/lib/account/context")
local Status = require("../../../plugin/lib/account/status")
local Resolve = require("../../../plugin/lib/account/resolve")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local ACCOUNTS = '[{"id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"]},'
	.. ' {"id": "prod", "label": "Live", "account_id": "1234567", "auth_ids": ["demo-prod"]}]'
local CFG = Config.parse('{"accounts": ' .. ACCOUNTS .. "}", json.decode)
local OFF = Config.parse('{"status": {"enabled": false}, "accounts": ' .. ACCOUNTS .. "}", json.decode)

local function project(authId: string?): Context.Context
	return { projectRoot = "/r/sdf/billing", projectName = "billing", authId = authId, problem = nil }
end

local function only(segs: { Status.Segment }?): Status.Segment
	expect(segs ~= nil).toBe(true)
	local list = segs :: { Status.Segment }
	expect(#list).toBe(1)
	return list[1]
end

describe("status line account indicator", function()
	it("shows the sandbox a project deploys to, quietly", function()
		local s = only(Status.segments(project("demo-sb"), { config = CFG, cache = {}, now = 0 }))
		expect(s.text).toBe("billing -> SB1")
		expect(s.tone).toBe("muted")
	end)

	it("shouts when the project deploys to production", function()
		local s = only(Status.segments(project("demo-prod"), { config = CFG, cache = {}, now = 0 }))
		expect(s.text).toBe("billing -> Live PROD")
		expect(s.tone).toBe("error")
	end)

	it("does not repeat PROD when the label already says it", function()
		local cfg = Config.parse(
			'{"accounts": [{"id": "p", "label": "PROD", "account_id": "1234567", "auth_ids": ["p"]}]}',
			json.decode
		)
		expect(only(Status.segments(project("p"), { config = cfg, cache = {}, now = 0 })).text).toBe("billing -> PROD")
	end)

	it("uses the CLI's cached answer for an auth id the config does not list", function()
		local cache: Resolve.Cache = { other = { authId = "other", accountId = "7654321_SB2", at = 0 } }
		local s = only(Status.segments(project("other"), { config = CFG, cache = cache, now = 1 }))
		expect(s.text).toBe("billing -> 7654321_SB2")
		expect(s.tone).toBe("muted")
	end)

	it("warns about an auth id it could not verify, since unknown is treated as production elsewhere", function()
		local s = only(Status.segments(project("mystery"), { config = CFG, cache = {}, now = 0 }))
		expect(s.text).toBe("billing -> mystery? (unverified)")
		expect(s.tone).toBe("warning")
	end)

	it("says so when the project has no default auth id", function()
		local s = only(Status.segments(project(nil), { config = CFG, cache = {}, now = 0 }))
		expect(s.text).toBe("billing -> no auth id")
	end)

	it("opens the doctor on click, where the account can be checked", function()
		local s = only(Status.segments(project("demo-sb"), { config = CFG, cache = {}, now = 0 }))
		expect(s.command).toBe("plugin.tern-netsuite.doctor")
		expect(s.icon).toBe(Status.ICON)
	end)

	it("adds nothing outside an SDF project", function()
		expect(Status.segments(nil, { config = CFG, cache = {}, now = 0 })).toBeNil()
	end)

	it("adds nothing when the user turned the indicator off", function()
		expect(Status.segments(project("demo-prod"), { config = OFF, cache = {}, now = 0 })).toBeNil()
	end)
end)

describe("status line health badge", function()
	local BADGES = { ["1234567_SB1"] = "3 err/1h", ["1234567"] = "Stuck orders" }

	it("adds the account's health problems next to the project, in the error tone", function()
		local segs = Status.segments(project("demo-sb"), { config = CFG, cache = {}, now = 0 }, BADGES)
		local list = segs :: { Status.Segment }
		expect(#list).toBe(2)
		expect(list[1].text).toBe("billing -> SB1")
		expect(list[1].tone).toBe("muted")
		expect(list[2].text).toBe("3 err/1h")
		expect(list[2].tone).toBe("error")
		expect(list[2].command).toBe(Status.HEALTH_COMMAND)
	end)

	it("matches health to the account the project deploys to, not to other accounts", function()
		local segs = Status.segments(project("demo-prod"), { config = CFG, cache = {}, now = 0 }, BADGES)
		expect((segs :: { Status.Segment })[2].text).toBe("Stuck orders")
	end)

	it("adds nothing when the account is healthy or its health is unknown", function()
		only(Status.segments(project("demo-sb"), { config = CFG, cache = {}, now = 0 }, {}))
		only(Status.segments(project("demo-sb"), { config = CFG, cache = {}, now = 0 }, nil))
	end)

	it("adds nothing for an auth id it has not resolved to an account", function()
		only(Status.segments(project("mystery"), { config = CFG, cache = {}, now = 0 }, BADGES))
		only(Status.segments(project(nil), { config = CFG, cache = {}, now = 0 }, BADGES))
	end)

	it("stays off when the user turned the indicator off", function()
		expect(Status.segments(project("demo-sb"), { config = OFF, cache = {}, now = 0 }, BADGES)).toBeNil()
	end)
end)

return nil
