--!strict
local Config = require("../../../plugin/lib/config")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function parse(text: string?)
	return Config.parse(text, json.decode)
end

local function paths(diags: { Config.Diagnostic }): { string }
	local out = {}
	for i, d in diags do
		out[i] = d.path
	end
	return out
end

local function levelOf(diags: { Config.Diagnostic }, path: string): string?
	for _, d in diags do
		if d.path == path then
			return d.level
		end
	end
	return nil
end

describe("config file location", function()
	it("prefers XDG_CONFIG_HOME so users with relocated dotfiles are honored", function()
		expect(Config.path({ XDG_CONFIG_HOME = "/x", HOME = "/home/u" })).toBe("/x/tern-netsuite/config.json")
	end)

	it("falls back to ~/.config when XDG_CONFIG_HOME is unset", function()
		expect(Config.path({ HOME = "/home/u" })).toBe("/home/u/.config/tern-netsuite/config.json")
	end)

	it("has no path when neither variable is known, instead of guessing a relative one", function()
		expect(Config.path({})).toBeNil()
	end)
end)

describe("missing or broken files never take the plugin down", function()
	it("uses the defaults silently when there is no file", function()
		local cfg, diags = parse(nil)
		expect(cfg).toEqual(Config.defaults())
		expect(#diags).toBe(0)
	end)

	it("reports invalid JSON as one error and keeps every default", function()
		local cfg, diags = parse("{ not json")
		expect(cfg).toEqual(Config.defaults())
		expect(#diags).toBe(1)
		expect(diags[1].level).toBe("error")
		expect(diags[1].path).toBe("")
	end)

	it("rejects a top-level value that is not an object", function()
		local cfg, diags = parse("[1, 2]")
		expect(cfg).toEqual(Config.defaults())
		expect(diags[1].level).toBe("error")
	end)
end)

describe("safety defaults", function()
	it("confirms production deploys and keeps connections read-only unless the user opts out", function()
		local cfg = Config.defaults()
		expect(cfg.guard.confirm_production).toBe(true)
		expect(cfg.guard.typed_confirmation).toBe(true)
		expect(cfg.connections).toEqual({})
	end)

	it("falls back to the safe default when a safety switch has the wrong type", function()
		local cfg, diags = parse('{"guard": {"confirm_production": "no"}}')
		expect(cfg.guard.confirm_production).toBe(true)
		expect(levelOf(diags, "guard.confirm_production")).toBe("error")
	end)

	it("guards exactly the commands that change an account by default", function()
		-- object:update only rewrites local project files from the account.
		expect(Config.defaults().guard.commands).toEqual({ "project:deploy", "file:upload" })
	end)
end)

describe("scalar validation names the exact key", function()
	it("keeps valid values", function()
		local cfg, diags = parse('{"suitecloud": {"program": "/opt/bin/suitecloud", "timeout_ms": 5000}}')
		expect(cfg.suitecloud.program).toBe("/opt/bin/suitecloud")
		expect(cfg.suitecloud.timeout_ms).toBe(5000)
		expect(#diags).toBe(0)
	end)

	it("replaces an out-of-range number with its default", function()
		local cfg, diags = parse('{"monitor": {"poll_seconds": 1}}')
		expect(cfg.monitor.poll_seconds).toBe(Config.defaults().monitor.poll_seconds)
		expect(levelOf(diags, "monitor.poll_seconds")).toBe("error")
	end)

	it("rejects fractional values where an integer is required", function()
		local _, diags = parse('{"general": {"max_lines": 10.5}}')
		expect(levelOf(diags, "general.max_lines")).toBe("error")
	end)

	it("rejects an empty program name instead of running an empty argv", function()
		local cfg, diags = parse('{"suitecloud": {"program": ""}}')
		expect(cfg.suitecloud.program).toBe("suitecloud")
		expect(levelOf(diags, "suitecloud.program")).toBe("error")
	end)

	it("warns about unknown keys so typos do not silently do nothing", function()
		local _, diags = parse('{"gaurd": {}, "guard": {"confirm_prod": false}}')
		expect(levelOf(diags, "gaurd")).toBe("warning")
		expect(levelOf(diags, "guard.confirm_prod")).toBe("warning")
	end)

	it("warns when the file was written for a newer schema", function()
		local _, diags = parse('{"schema_version": 99}')
		expect(levelOf(diags, "schema_version")).toBe("warning")
	end)
end)

describe("guard commands", function()
	it("keeps only real SuiteCloud command names, and a typo never unguards a default command", function()
		local cfg, diags = parse('{"guard": {"commands": ["project:deploy", "rm -rf", "file:uplaod"]}}')
		expect(cfg.guard.commands).toEqual({ "project:deploy", "file:upload" })
		expect(levelOf(diags, "guard.commands[2]")).toBe("error")
		expect(levelOf(diags, "guard.commands[3]")).toBe("error")
	end)

	it("keeps a deliberately narrowed list of valid commands", function()
		local cfg, diags = parse('{"guard": {"commands": ["project:deploy"]}}')
		expect(cfg.guard.commands).toEqual({ "project:deploy" })
		expect(#diags).toBe(0)
	end)

	it("lets an explicit empty list turn the guard off, with a warning", function()
		local cfg, diags = parse('{"guard": {"commands": []}}')
		expect(cfg.guard.commands).toEqual({})
		expect(levelOf(diags, "guard.commands")).toBe("warning")
	end)

	it("guards the defaults when every entry is invalid", function()
		local cfg = parse('{"guard": {"commands": ["project:deploy "]}}')
		expect(cfg.guard.commands).toEqual({ "project:deploy", "file:upload" })
	end)
end)

describe("lens wrappers", function()
	it("maps a wrapper command prefix to the SuiteCloud command it runs", function()
		local cfg, diags = parse('{"lens": {"wrappers": [{"prefix": "npm run deploy", "command": "project:deploy"}]}}')
		expect(cfg.lens.wrappers).toEqual({ { prefix = "npm run deploy", command = "project:deploy" } })
		expect(#diags).toBe(0)
	end)

	it("drops a wrapper whose command is not a SuiteCloud command", function()
		local cfg, diags = parse('{"lens": {"wrappers": [{"prefix": "make deploy", "command": "deploy"}]}}')
		expect(cfg.lens.wrappers).toEqual({})
		expect(levelOf(diags, "lens.wrappers[1].command")).toBe("error")
	end)

	it("drops a wrapper with a blank prefix, which would claim every command", function()
		local cfg = parse('{"lens": {"wrappers": [{"prefix": "  ", "command": "project:deploy"}]}}')
		expect(cfg.lens.wrappers).toEqual({})
	end)
end)

describe("accounts", function()
	it("accepts an account and leaves production unset so it is inferred from the account id", function()
		local cfg, diags = parse('{"accounts": [{"id": "sb", "account_id": "1234567_SB1", "auth_ids": ["dev-sb"]}]}')
		expect(#diags).toBe(0)
		expect(cfg.accounts[1].id).toBe("sb")
		expect(cfg.accounts[1].account_id).toBe("1234567_SB1")
		expect(cfg.accounts[1].auth_ids).toEqual({ "dev-sb" })
		expect(cfg.accounts[1].production).toBeNil()
	end)

	it("drops an account without an account_id, since nothing could be matched to it", function()
		local cfg, diags = parse('{"accounts": [{"id": "sb"}]}')
		expect(cfg.accounts).toEqual({})
		expect(levelOf(diags, "accounts[1].account_id")).toBe("error")
	end)

	it("treats a malformed production flag as production, since the user meant to mark something", function()
		local cfg, diags = parse(
			'{"accounts": [{"id": "uat", "account_id": "1234567_SB2", "production": "true", "auth_ids": ["uat"]}]}'
		)
		expect(cfg.accounts[1].production).toBe(true)
		expect(levelOf(diags, "accounts[1].production")).toBe("error")
	end)

	it("drops a second account with the same account id, whose production flag could otherwise be ignored", function()
		local cfg, diags = parse(
			'{"accounts": [{"id": "a", "account_id": "1234567_SB1"},'
				.. ' {"id": "b", "account_id": "1234567_sb1", "production": true}]}'
		)
		expect(#cfg.accounts).toBe(1)
		expect(levelOf(diags, "accounts[2].account_id")).toBe("error")
	end)

	it("keeps no scaffold template directory by default, so built-in skeletons are used", function()
		expect(Config.defaults().scaffold.templates_dir).toBeNil()
		local cfg, diags = parse('{"scaffold": {"templates_dir": "~/sdf-templates"}}')
		expect(cfg.scaffold.templates_dir).toBe("~/sdf-templates")
		expect(#diags).toBe(0)
	end)

	it("drops a second account reusing an id so lookups stay unambiguous", function()
		local cfg, diags = parse('{"accounts": [{"id": "a", "account_id": "1"}, {"id": "a", "account_id": "2"}]}')
		expect(#cfg.accounts).toBe(1)
		expect(cfg.accounts[1].account_id).toBe("1")
		expect(levelOf(diags, "accounts[2].id")).toBe("error")
	end)

	it("rejects an auth id claimed by two accounts, which would make the deploy target ambiguous", function()
		local cfg, diags = parse(
			'{"accounts": [{"id": "a", "account_id": "1", "auth_ids": ["x"]},'
				.. ' {"id": "b", "account_id": "2", "auth_ids": ["x"]}]}'
		)
		expect(cfg.accounts[2].auth_ids).toEqual({})
		expect(levelOf(diags, "accounts[2].auth_ids[1]")).toBe("error")
	end)

	it("normalizes account ids to upper case, as NetSuite treats them case-insensitively", function()
		local cfg = parse('{"accounts": [{"id": "sb", "account_id": "1234567_sb1"}]}')
		expect(cfg.accounts[1].account_id).toBe("1234567_SB1")
	end)
end)

describe("connections", function()
	local ACCOUNT = '{"id": "sb", "account_id": "1234567_SB1"}'

	it("defaults to read-only REST SuiteQL with TBA", function()
		local cfg, diags = parse('{"accounts": [' .. ACCOUNT .. '], "connections": [{"id": "c", "account": "sb"}]}')
		expect(#diags).toBe(0)
		local c = cfg.connections[1]
		expect(c.read_only).toBe(true)
		expect(c.auth).toBe("tba")
		expect(c.transport).toBe("rest")
		expect(c.restlet).toBeNil()
	end)

	it("drops a connection naming an unknown account", function()
		local cfg, diags = parse('{"connections": [{"id": "c", "account": "nope"}]}')
		expect(cfg.connections).toEqual({})
		expect(levelOf(diags, "connections[1].account")).toBe("error")
	end)

	it("drops a connection id that could not name its keychain entries, before the user types any secret", function()
		local long = string.rep("a", 49)
		local cfg, diags = parse(
			'{"accounts": ['
				.. ACCOUNT
				.. '], "connections": [{"id": "Sandbox Restlet", "account": "sb"}, {"id": "'
				.. long
				.. '", "account": "sb"}, {"id": "'
				.. string.rep("a", 48)
				.. '", "account": "sb"}]}'
		)
		expect(#cfg.connections).toBe(1)
		expect(levelOf(diags, "connections[1].id")).toBe("error")
		expect(levelOf(diags, "connections[2].id")).toBe("error")
	end)

	it("requires restlet script and deploy ids for the restlet transport", function()
		local cfg, diags = parse(
			'{"accounts": [' .. ACCOUNT .. '], "connections": [{"id": "c", "account": "sb", "transport": "restlet"}]}'
		)
		expect(cfg.connections).toEqual({})
		expect(levelOf(diags, "connections[1].restlet")).toBe("error")
	end)

	it("keeps the restlet request and response mapping the user configured", function()
		local cfg, diags = parse(
			'{"accounts": ['
				.. ACCOUNT
				.. '], "connections": [{"id": "c", "account": "sb", "transport": "restlet",'
				.. ' "restlet": {"script": "customscript_q", "deploy": "customdeploy_q",'
				.. ' "query_field": "q", "params_field": "p", "rows_path": "data.rows",'
				.. ' "extra": {"action": "suiteql"}}}]}'
		)
		expect(#diags).toBe(0)
		expect(cfg.connections[1].restlet).toEqual({
			script = "customscript_q",
			deploy = "customdeploy_q",
			query_field = "q",
			params_field = "p",
			rows_path = "data.rows",
			extra = { action = "suiteql" },
		})
	end)

	it("rejects an unknown auth method rather than sending unsigned requests", function()
		local cfg, diags =
			parse('{"accounts": [' .. ACCOUNT .. '], "connections": [{"id": "c", "account": "sb", "auth": "basic"}]}')
		expect(cfg.connections).toEqual({})
		expect(levelOf(diags, "connections[1].auth")).toBe("error")
	end)
end)

describe("deploy history", function()
	it("keeps CI runs off by default, since gh may not be installed or authenticated", function()
		local cfg = Config.defaults()
		expect(cfg.history.ci).toBeNil()
		expect(cfg.history.max_entries).toBe(500)
	end)

	it("accepts a CI workflow and reports bad history keys at their exact path", function()
		local cfg, diags = parse('{"history": {"max_entries": 5, "ci": {"workflow": "deploy.yml", "limit": 3}}}')
		expect((cfg.history.ci :: any).workflow).toBe("deploy.yml")
		expect((cfg.history.ci :: any).limit).toBe(3)
		expect(levelOf(diags, "history.max_entries")).toBe("error")
		expect(levelOf(diags, "history")).toBeNil()
	end)
end)

describe("built-in script error thresholds", function()
	it("default to alerting on any error, so a quiet account stays quiet and a noisy one is visible", function()
		expect(Config.defaults().monitor.script_errors).toEqual({ enabled = true, hour_error_at = 1, day_warn_at = 1 })
	end)

	it("can be raised for accounts that always log some errors, without disabling the check", function()
		local cfg, diags = parse('{"monitor": {"script_errors": {"hour_error_at": 20, "day_warn_at": 50}}}')
		expect(cfg.monitor.script_errors).toEqual({ enabled = true, hour_error_at = 20, day_warn_at = 50 })
		expect(#diags).toBe(0)
	end)

	it("rejects a zero threshold, which would mark every account in error", function()
		local cfg, diags = parse('{"monitor": {"script_errors": {"hour_error_at": 0}}}')
		expect(cfg.monitor.script_errors.hour_error_at).toBe(1)
		expect(levelOf(diags, "monitor.script_errors.hour_error_at")).toBe("error")
	end)
end)

describe("monitor checks", function()
	local BASE = '{"accounts": [{"id": "sb", "account_id": "1_SB1"}], "connections": [{"id": "c", "account": "sb"}],'

	it("accepts a freshness check with a max age", function()
		local cfg, diags = parse(
			BASE
				.. ' "monitor": {"checks": [{"id": "sync", "label": "Sync", "connection": "c",'
				.. ' "kind": "freshness", "query": "SELECT MAX(x) AS last FROM t", "max_age_minutes": 90}]}}'
		)
		expect(#diags).toBe(0)
		expect(cfg.monitor.checks[1].kind).toBe("freshness")
		expect(cfg.monitor.checks[1].max_age_minutes).toBe(90)
	end)

	it("drops a freshness check without max_age_minutes, which could never alert", function()
		local cfg, diags = parse(
			BASE
				.. ' "monitor": {"checks": [{"id": "sync", "connection": "c", "kind": "freshness",'
				.. ' "query": "SELECT 1"}]}}'
		)
		expect(cfg.monitor.checks).toEqual({})
		expect(levelOf(diags, "monitor.checks[1].max_age_minutes")).toBe("error")
	end)

	it("drops a check whose connection does not exist", function()
		local cfg, diags = parse(
			BASE .. ' "monitor": {"checks": [{"id": "n", "connection": "x", "kind": "count", "query": "SELECT 1"}]}}'
		)
		expect(cfg.monitor.checks).toEqual({})
		expect(levelOf(diags, "monitor.checks[1].connection")).toBe("error")
	end)
end)

describe("shipped example config", function()
	it("parses without a single diagnostic, so users can copy it as a starting point", function()
		local _, diags = parse(fixtures.read("examples/config.json"))
		expect(paths(diags)).toEqual({})
	end)
end)

describe("parsed config", function()
	it("is frozen so no callback can mutate the shared snapshot", function()
		local cfg = parse('{"accounts": [{"id": "sb", "account_id": "1"}]}')
		expect(table.isfrozen(cfg)).toBe(true)
		expect(table.isfrozen(cfg.accounts[1])).toBe(true)
	end)
end)

return nil
