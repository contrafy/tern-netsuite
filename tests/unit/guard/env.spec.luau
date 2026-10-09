--!strict
local Config = require("../../../plugin/lib/config")
local Env = require("../../../plugin/lib/guard/env")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local SPOOL = "/data/tern-netsuite/spool"

local function cfg(text: string): Config.Config
	local c = Config.parse(text, json.decode)
	return c
end

describe("the environment new panes get for the shell guard", function()
	it("points the guard at the plugin's spool and guards deploy and upload by default", function()
		local env = Env.forSpawn(Config.defaults(), SPOOL)
		expect(env.TNS_SPOOL).toBe(SPOOL)
		expect(env.TNS_GUARD_COMMANDS).toBe("project:deploy file:upload")
		expect(env.TNS_GUARD_CONFIRM).toBe("1")
		expect(env.TNS_GUARD_TIMEOUT).toBe("600")
		expect(env.TNS_GUARD_ACCOUNTS).toBe("")
		expect(env.TNS_SUITECLOUD).toBeNil()
	end)

	it("passes the configured guarded commands and timeout", function()
		local env =
			Env.forSpawn(cfg([[{"guard": {"commands": ["project:deploy", "object:update"], "timeout_s": 120}}]]), SPOOL)
		expect(env.TNS_GUARD_COMMANDS).toBe("project:deploy object:update")
		expect(env.TNS_GUARD_TIMEOUT).toBe("120")
	end)

	it("lets the user turn production confirmation off explicitly", function()
		local env = Env.forSpawn(cfg([[{"guard": {"confirm_production": false}}]]), SPOOL)
		expect(env.TNS_GUARD_CONFIRM).toBe("0")
	end)

	it("hands over only explicit production flags, so the shell classifies accounts like the plugin", function()
		local env = Env.forSpawn(
			cfg([[{"accounts": [
				{"id": "prod", "account_id": "1234567", "production": true},
				{"id": "odd", "account_id": "7654321_sb1", "production": true},
				{"id": "demo", "account_id": "DEMO-ACCT", "production": false},
				{"id": "sb", "account_id": "1234567_SB1"}
			]}]]),
			SPOOL
		)
		expect(env.TNS_GUARD_ACCOUNTS).toBe("1234567=prod 7654321_SB1=prod DEMO-ACCT=nonprod")
	end)

	it("drops account ids the shell could not match safely (they stay production there)", function()
		local env =
			Env.forSpawn(cfg([[{"accounts": [{"id": "x", "account_id": "12 34=x", "production": false}]}]]), SPOOL)
		expect(env.TNS_GUARD_ACCOUNTS).toBe("")
	end)

	it("pins the configured CLI only when it is an absolute path", function()
		expect(Env.forSpawn(cfg([[{"suitecloud": {"program": "/opt/sc/bin/suitecloud"}}]]), SPOOL).TNS_SUITECLOUD).toBe(
			"/opt/sc/bin/suitecloud"
		)
		expect(Env.forSpawn(cfg([[{"suitecloud": {"program": "npx suitecloud"}}]]), SPOOL).TNS_SUITECLOUD).toBeNil()
	end)
end)

return nil
