--!strict
local Checks = require("../../../../plugin/lib/monitor/health/checks")
local Config = require("../../../../plugin/lib/config")
local Dates = require("../../../../plugin/lib/monitor/health/dates")
local Sql = require("../../../../plugin/lib/ns/sql")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Spec = Checks.Spec

local CFG = Config.parse(
	[[{
	"accounts": [{"id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"]}],
	"connections": [{"id": "demo-sb", "account": "sb", "auth": "tba", "transport": "rest"}],
	"monitor": {"poll_seconds": 300, "checks": [
		{"id": "orders", "label": "Stuck orders", "connection": "demo-sb", "kind": "count",
		 "query": "SELECT COUNT(*) AS n FROM transaction", "warn_at": 5, "error_at": 10},
		{"id": "sync", "label": "Order sync", "connection": "demo-sb", "kind": "freshness",
		 "query": "SELECT MAX(lastmodifieddate) AS last FROM customrecord_demo", "max_age_minutes": 90}
	]}
}]],
	json.decode
)

local function spec(kind: string): Spec
	for _, s in Checks.specs(CFG) do
		if s.kind == kind then
			return s
		end
	end
	error("no spec of kind " .. kind)
end

-- Rows of a fixture response: REST `items` or the RESTlet's `rows`.
local function rows(path: string): { any }
	local doc = json.decode(fixtures.read("monitor/health/" .. path))
	return doc.items or doc.rows
end

local NOW = 5000000
local function clockAt(text: string): Checks.Clock
	return { server = (Dates.parse(text) :: Dates.Stamp).t, at = NOW }
end

describe("built-in and configured health checks", function()
	it("polls script errors first so the server clock is known before any freshness check", function()
		local list = Checks.specs(CFG)
		expect(list[1].kind).toBe("errors")
		local kinds = {}
		for i, s in list do
			kinds[i] = s.kind
			expect(s.connection).toBe("demo-sb")
			expect(s.interval).toBe(300)
		end
		expect(kinds).toEqual({ "errors", "hourly", "last_error", "deployments", "count", "freshness" })
	end)

	it("sends only queries the read-only guard accepts", function()
		for _, s in Checks.specs(CFG) do
			local ok, why = Sql.readOnly(s.sql)
			expect(why).toBeNil()
			expect(ok).toBe(true)
		end
	end)

	it("adds no checks without a configured connection", function()
		expect(#Checks.specs(Config.defaults())).toBe(0)
	end)
end)

describe("script errors", function()
	it("is an error when anything failed in the last hour (REST returns numbers as strings)", function()
		local r = Checks.evaluate(spec("errors"), rows("errors-rest.json"), nil, NOW, nil)
		expect(r.state).toBe("error")
		expect(r.h1).toBe(5)
		expect(r.h24).toBe(543)
		expect(r.value).toBe("5 in 1 h · 543 in 24 h")
	end)

	it("reads the RESTlet's typed numbers the same way", function()
		local r = Checks.evaluate(spec("errors"), rows("errors-restlet.json"), nil, NOW, nil)
		expect(r.h1).toBe(5)
		expect(r.h24).toBe(543)
	end)

	it("records the server clock so ages are measured in NetSuite's time zone", function()
		local r = Checks.evaluate(spec("errors"), rows("errors-rest.json"), nil, NOW, nil)
		expect(r.clock ~= nil).toBe(true)
		expect(Dates.format((r.clock :: Checks.Clock).server)).toBe("2026-10-08 22:27:20")
		expect((r.clock :: Checks.Clock).at).toBe(NOW)
	end)

	it("warns for errors earlier in the day and is quiet for a clean day", function()
		local warn = Checks.evaluate(
			spec("errors"),
			{ { h1 = "0", h24 = "3", server_now = "2026-10-08 22:27:20" } },
			nil,
			NOW,
			nil
		)
		expect(warn.state).toBe("warn")
		local ok =
			Checks.evaluate(spec("errors"), { { h1 = 0, h24 = 0, server_now = "2026-10-08 22:27:20" } }, nil, NOW, nil)
		expect(ok.state).toBe("ok")
	end)

	local function withScriptErrors(se: string): Config.Config
		return Config.parse([[{
			"accounts": [{"id": "sb", "account_id": "1234567_SB1"}],
			"connections": [{"id": "demo-sb", "account": "sb"}],
			"monitor": {"script_errors": ]] .. se .. [[, "checks": [
				{"id": "sync", "connection": "demo-sb", "kind": "freshness",
				 "query": "SELECT MAX(lastmodifieddate) AS last FROM customrecord_demo", "max_age_minutes": 90}
			]}
		}]], json.decode)
	end

	local function kindsOf(cfg: Config.Config): { string }
		local out = {}
		for i, s in Checks.specs(cfg) do
			out[i] = s.kind
		end
		return out
	end

	it("uses the configured thresholds so an account that always logs a few errors is not always red", function()
		local cfg = withScriptErrors('{"hour_error_at": 10, "day_warn_at": 100}')
		local s = Checks.specs(cfg)[1]
		local function at(h1: number, h24: number): Checks.Result
			return Checks.evaluate(s, { { h1 = h1, h24 = h24, server_now = "2026-10-08 22:27:20" } }, nil, NOW, nil)
		end
		expect(at(5, 99).state).toBe("ok")
		expect(at(5, 100).state).toBe("warn")
		expect(at(10, 100).state).toBe("error")
		expect(at(5, 99).threshold).toBe("error ≥ 10 in 1 h · warn ≥ 100 in 24 h")
	end)

	it("drops every script-error query when disabled, keeping only a clock for freshness checks", function()
		local kinds = kindsOf(withScriptErrors('{"enabled": false}'))
		expect(kinds).toEqual({ "clock", "deployments", "freshness" })
		local clock = Checks.specs(withScriptErrors('{"enabled": false}'))[1]
		expect(clock.detail).toBe(true)
		local readOnly = Sql.readOnly(clock.sql)
		expect(readOnly).toBe(true)
		local r = Checks.evaluate(clock, { { server_now = "2026-10-08 22:27:20" } }, nil, NOW, nil)
		expect(r.state).toBe("ok")
		expect(Dates.format((r.clock :: Checks.Clock).server)).toBe("2026-10-08 22:27:20")
	end)

	it("needs no clock query when script errors are off and nothing checks freshness", function()
		local cfg = Config.parse(
			[[{"accounts": [{"id": "sb", "account_id": "1234567_SB1"}],
			"connections": [{"id": "demo-sb", "account": "sb"}],
			"monitor": {"script_errors": {"enabled": false}}}]],
			json.decode
		)
		expect(kindsOf(cfg)).toEqual({ "deployments" })
	end)
end)

describe("errors per hour", function()
	it("lays out 24 hourly buckets ending at the server's current hour, zero where nothing failed", function()
		local r = Checks.evaluate(spec("hourly"), rows("hourly-rest.json"), nil, NOW, nil)
		local series = r.series :: { number }
		expect(#series).toBe(24)
		expect(series[24]).toBe(5)
		expect(series[16]).toBe(194)
		expect(series[7]).toBe(10)
		expect(series[6]).toBe(0)
		expect(r.seriesEnd).toBe("2026-10-08 22:00")
	end)

	it("shows a flat line when nothing failed (no rows at all)", function()
		local r = Checks.evaluate(spec("hourly"), {}, nil, NOW, clockAt("2026-10-08 22:27:20"))
		expect(#(r.series :: { number })).toBe(24)
		expect((r.series :: { number })[24]).toBe(0)
		expect(r.state).toBe("ok")
	end)
end)

describe("last error and deployments", function()
	it("keeps the newest error's script, title and message", function()
		local r = Checks.evaluate(spec("last_error"), rows("last-error-restlet.json"), nil, NOW, nil)
		local e = r.lastError :: Checks.LastError
		expect(e.at).toBe("2026-10-08 22:25:36")
		expect(e.title).toBe("restlet.error")
		expect(e.script).toBe("customscript_demo_suiteql")
		expect(e.scriptName).toBe("Demo SuiteQL RESTlet")
		expect(e.detail).toContain("INVALID_NUMBER_OF_PARAMETERS")
	end)

	it("lists deployments still in testing or not deployed, warning only for testing ones", function()
		local r = Checks.evaluate(spec("deployments"), rows("deployments-rest.json"), nil, NOW, nil)
		local list = r.deployments :: { Checks.Deployment }
		expect(#list).toBe(2)
		expect(list[1].deployed).toBe(false)
		expect(list[2].status).toBe("TESTING")
		expect(r.state).toBe("warn")
		expect(r.value).toBe("1 testing · 1 not deployed")
	end)

	it("treats a not-deployed deployment alone as information, not a warning", function()
		local only = { rows("deployments-rest.json")[1] }
		expect(Checks.evaluate(spec("deployments"), only, nil, NOW, nil).state).toBe("ok")
		expect(Checks.evaluate(spec("deployments"), {}, nil, NOW, nil).value).toBe("all released and deployed")
	end)

	it("says the list is cut off when NetSuite has more than it shows", function()
		local many = {}
		for i = 1, Checks.MAX_DEPLOYMENTS + 1 do
			many[i] = { scriptid = "customdeploy_" .. i, status = "TESTING", isdeployed = "T" }
		end
		local r = Checks.evaluate(spec("deployments"), many, nil, NOW, nil)
		expect(#(r.deployments :: { any })).toBe(Checks.MAX_DEPLOYMENTS)
		expect(r.more).toBe(true)
		expect(r.value).toBe("100+ testing · 0 not deployed")
	end)
end)

describe("configured count checks", function()
	local function count(v: any): Checks.Result
		return Checks.evaluate(spec("count"), { { links = {}, n = v } }, nil, NOW, nil)
	end

	it("compares the number against warn_at and error_at", function()
		expect(count("4").state).toBe("ok")
		expect(count("5").state).toBe("warn")
		expect(count(10).state).toBe("error")
		expect(count("4").threshold).toBe("warn ≥ 5 · error ≥ 10")
		expect(count("12").value).toBe("12")
	end)

	it("counts an empty result or a null as zero", function()
		expect(Checks.evaluate(spec("count"), {}, nil, NOW, nil).value).toBe("0")
		expect(Checks.evaluate(spec("count"), { {} }, nil, NOW, nil).state).toBe("ok")
	end)

	it("fails clearly when the column is not a number", function()
		local r = count("lots")
		expect(r.state).toBe("failed")
		expect(r.error).toContain("not a number")
	end)

	it("picks the column named count when the query returns several", function()
		local r = Checks.evaluate(spec("count"), { { label = "x", count = "7" } }, nil, NOW, nil)
		expect(r.value).toBe("7")
	end)

	it("refuses to guess between several unnamed columns", function()
		local r = Checks.evaluate(spec("count"), { { a = "1", b = "2" } }, nil, NOW, nil)
		expect(r.state).toBe("failed")
		expect(r.error).toContain("a, b")
	end)

	it("reports the query's own error instead of a value", function()
		local r = Checks.evaluate(spec("count"), nil, {
			kind = "query",
			message = "Invalid search: unknown field",
			code = "INVALID_SEARCH",
		}, NOW, nil)
		expect(r.state).toBe("failed")
		expect(r.error).toBe("Invalid search: unknown field")
	end)
end)

describe("configured freshness checks", function()
	local CLOCK = clockAt("2026-10-08 22:00:00")

	local function fresh(v: any, now: number?, clock: Checks.Clock?): Checks.Result
		return Checks.evaluate(spec("freshness"), { { last = v } }, nil, now or NOW, clock or CLOCK)
	end

	it("is fine while the newest timestamp is younger than max_age_minutes", function()
		local r = fresh("2026-10-08 21:00:00")
		expect(r.state).toBe("ok")
		expect(r.value).toBe("1 h ago")
		expect(r.threshold).toBe("max 90 min")
	end)

	it("is an error once it is older", function()
		expect(fresh("2026-10-08 20:29:00").state).toBe("error")
	end)

	it("advances with the local clock between server clock readings", function()
		expect(fresh("2026-10-08 21:00:00", NOW + 31 * 60).state).toBe("error")
	end)

	it("gives a date-only value the benefit of the doubt until that day is over", function()
		local today = fresh("10/8/2026")
		expect(today.state).toBe("ok")
		expect(today.value).toContain("date only")
		expect(fresh("10/7/2026").state).toBe("error")
	end)

	it("treats an empty table or a null timestamp as stale", function()
		expect(Checks.evaluate(spec("freshness"), {}, nil, NOW, CLOCK).state).toBe("error")
		local r = fresh("")
		expect(r.state).toBe("error")
		expect(r.value).toBe("never")
	end)

	it("fails clearly for a value that is not a date", function()
		local r = fresh("soon")
		expect(r.state).toBe("failed")
		expect(r.error).toContain("not a date")
	end)

	it("waits for the server clock instead of comparing against another time zone", function()
		local r = Checks.evaluate(spec("freshness"), { { last = "2026-10-08 21:00:00" } }, nil, NOW, nil)
		expect(r.state).toBe("pending")
	end)
end)

return nil
