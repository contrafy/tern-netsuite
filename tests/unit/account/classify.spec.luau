--!strict
local Classify = require("../../../plugin/lib/account/classify")
local Config = require("../../../plugin/lib/config")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function cfg(text: string): Config.Config
	local c = Config.parse(text, json.decode)
	return c
end

local NONE = Config.defaults()

describe("inferring production from the account id", function()
	it("treats sandbox ids as non-production", function()
		expect(Classify.account("1234567_SB1", NONE).production).toBe(false)
		expect(Classify.account("1234567_SB12", NONE).production).toBe(false)
	end)

	it("treats release preview and test drive accounts as non-production", function()
		expect(Classify.account("1234567_RP", NONE).production).toBe(false)
		expect(Classify.account("TSTDRV1234567", NONE).production).toBe(false)
	end)

	it("treats a plain numeric id as production", function()
		expect(Classify.account("1234567", NONE).production).toBe(true)
	end)

	it("fails closed: an id it cannot recognise counts as production", function()
		local c = Classify.account("weird-id", NONE)
		expect(c.production).toBe(true)
		expect(c.reason).toBe("inferred")
	end)

	it("fails closed on sandbox-looking ids without the account number NetSuite always appends", function()
		for _, id in { "1234567_SB", "X_SB", "TSTDRV", "TSTDRVX" } do
			expect(Classify.account(id, NONE).production).toBe(true)
		end
	end)

	it("matches sandbox suffixes case-insensitively, as account ids are", function()
		expect(Classify.account("1234567_sb1", NONE).production).toBe(false)
	end)
end)

describe("configured accounts", function()
	local c = cfg(
		'{"accounts": [{"id": "qa", "label": "QA", "account_id": "7654321", "production": false, "auth_ids": ["qa"]},'
			.. ' {"id": "sb", "account_id": "1234567_SB1", "production": true, "auth_ids": ["sb"]}]}'
	)

	it("lets the user mark an account non-production explicitly", function()
		local r = Classify.account("7654321", c)
		expect(r.production).toBe(false)
		expect(r.reason).toBe("configured")
		expect(r.label).toBe("QA")
		expect((r.account :: Config.Account).id).toBe("qa")
	end)

	it("lets the user mark a sandbox as production (e.g. a UAT sandbox they treat as live)", function()
		expect(Classify.account("1234567_SB1", c).production).toBe(true)
	end)

	it("labels an unconfigured account with its id", function()
		expect(Classify.account("1111111_SB2", c).label).toBe("1111111_SB2")
	end)
end)

describe("auth ids", function()
	local c = cfg('{"accounts": [{"id": "sb", "account_id": "1234567_SB1", "auth_ids": ["dev-sb"]}]}')

	it("resolves a configured auth id to its account without asking the CLI", function()
		local r = Classify.authId("dev-sb", c)
		expect(r ~= nil).toBe(true)
		expect((r :: Classify.Result).production).toBe(false)
		expect((r :: Classify.Result).accountId).toBe("1234567_SB1")
	end)

	it("returns nil for an unknown auth id so the caller asks the CLI instead of guessing", function()
		expect(Classify.authId("other", c)).toBeNil()
	end)
end)

return nil
