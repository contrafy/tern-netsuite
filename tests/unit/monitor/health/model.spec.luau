--!strict
local Checks = require("../../../../plugin/lib/monitor/health/checks")
local Config = require("../../../../plugin/lib/config")
local Model = require("../../../../plugin/lib/monitor/health/model")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CFG = Config.parse(
	[[{
	"accounts": [{"id": "sb", "label": "SB1", "account_id": "1234567_sb1", "auth_ids": ["demo-sb"]}],
	"connections": [{"id": "demo-sb", "account": "sb", "auth": "tba", "transport": "rest"}],
	"monitor": {"checks": [
		{"id": "orders", "label": "Stuck orders", "connection": "demo-sb", "kind": "count",
		 "query": "SELECT COUNT(*) AS n FROM transaction", "error_at": 10}
	]}
}]],
	json.decode
)
local SPECS = Checks.specs(CFG)
local NOW = 1000

local function spec(id: string): Checks.Spec
	for _, s in SPECS do
		if s.id == id then
			return s
		end
	end
	error(id)
end

local function conn(): Model.Conn
	return Model.conns(CFG)[1]
end

local ERRORS_OK = { { server_now = "2026-10-08 22:00:00", h1 = "0", h24 = "0" } }
local ERRORS_BAD = { { server_now = "2026-10-08 22:00:00", h1 = "3", h24 = "9" } }

-- Feeds every check a healthy answer.
local function allOk(c: Model.Conn, now: number)
	Model.record(c, spec("errors"), Checks.evaluate(spec("errors"), ERRORS_OK, nil, now, c.clock))
	Model.record(c, spec("hourly"), Checks.evaluate(spec("hourly"), {}, nil, now, c.clock))
	Model.record(c, spec("last_error"), Checks.evaluate(spec("last_error"), {}, nil, now, c.clock))
	Model.record(c, spec("deployments"), Checks.evaluate(spec("deployments"), {}, nil, now, c.clock))
	Model.record(c, spec("orders"), Checks.evaluate(spec("orders"), { { n = "1" } }, nil, now, c.clock))
end

describe("connection health", function()
	it("knows each connection's account so the status line can match it to a project", function()
		local c = conn()
		expect(c.id).toBe("demo-sb")
		expect(c.accountId).toBe("1234567_SB1")
		expect(c.label).toBe("SB1")
	end)

	it("is pending until every check has answered once", function()
		local c = conn()
		expect(Model.state(c, SPECS)).toBe("pending")
		Model.record(c, spec("errors"), Checks.evaluate(spec("errors"), ERRORS_OK, nil, NOW, nil))
		expect(Model.state(c, SPECS)).toBe("pending")
		allOk(c, NOW)
		expect(Model.state(c, SPECS)).toBe("ok")
	end)

	it("keeps the server clock from the error count for later freshness checks", function()
		local c = conn()
		Model.record(c, spec("errors"), Checks.evaluate(spec("errors"), ERRORS_OK, nil, NOW, nil))
		expect(c.clock ~= nil).toBe(true)
	end)

	it("is in error as soon as any check is, even mid-round", function()
		local c = conn()
		allOk(c, NOW)
		Model.record(c, spec("errors"), Checks.evaluate(spec("errors"), ERRORS_BAD, nil, NOW, nil))
		expect(Model.state(c, SPECS)).toBe("error")
	end)

	it("separates a broken query (failed) from bad data (error)", function()
		local c = conn()
		allOk(c, NOW)
		Model.record(
			c,
			spec("orders"),
			Checks.evaluate(spec("orders"), nil, { kind = "query", message = "bad field" }, NOW, nil)
		)
		expect(Model.state(c, SPECS)).toBe("failed")
	end)

	it("is 'not connected' without credentials, whatever older results say", function()
		local c = conn()
		allOk(c, NOW)
		Model.disconnect(c, "no stored consumer key")
		expect(Model.state(c, SPECS)).toBe("not_connected")
		Model.reconnect(c)
		expect(Model.state(c, SPECS)).toBe("ok")
	end)
end)

describe("summary for the dashboard and the status line", function()
	it("names the problem in the badge: errors in the last hour, then failing checks", function()
		local c = conn()
		allOk(c, NOW)
		Model.record(c, spec("errors"), Checks.evaluate(spec("errors"), ERRORS_BAD, nil, NOW, nil))
		local s = Model.summary(c, SPECS, NOW, 120)
		expect(s.state).toBe("error")
		expect(s.badge).toBe("3 err/1h")
		Model.record(c, spec("orders"), Checks.evaluate(spec("orders"), { { n = "12" } }, nil, NOW, nil))
		expect(Model.summary(c, SPECS, NOW, 120).badge).toBe("3 err/1h · Stuck orders")
	end)

	it("has no badge when healthy, pending, warning or not connected", function()
		local c = conn()
		expect(Model.summary(c, SPECS, NOW, 120).badge).toBeNil()
		allOk(c, NOW)
		expect(Model.summary(c, SPECS, NOW, 120).badge).toBeNil()
		Model.disconnect(c, "no credentials")
		local s = Model.summary(c, SPECS, NOW, 120)
		expect(s.badge).toBeNil()
		expect(s.message).toBe("no credentials")
	end)

	it("shortens a long badge so the status line stays readable", function()
		local cfg = Config.parse(
			[[{
			"accounts": [{"id": "sb", "account_id": "1234567_SB1"}],
			"connections": [{"id": "c", "account": "sb"}],
			"monitor": {"checks": [
				{"id": "a", "connection": "c", "query": "SELECT 1 AS n FROM DUAL", "error_at": 1},
				{"id": "b", "connection": "c", "query": "SELECT 1 AS n FROM DUAL", "error_at": 1},
				{"id": "d", "connection": "c", "query": "SELECT 1 AS n FROM DUAL", "error_at": 1}
			]}
		}]],
			json.decode
		)
		local specs = Checks.specs(cfg)
		local c = Model.conns(cfg)[1]
		for _, s in specs do
			if s.kind == "count" then
				Model.record(c, s, Checks.evaluate(s, { { n = 1 } }, nil, NOW, nil))
			end
		end
		expect(Model.summary(c, specs, NOW, 120).badge).toBe("a · b +1")
	end)

	it("lists checks with value, threshold and run time, and hides detail-only queries unless they fail", function()
		local c = conn()
		allOk(c, NOW)
		local s = Model.summary(c, SPECS, NOW, 120)
		local ids = {}
		for i, row in s.checks do
			ids[i] = row.id
		end
		expect(ids).toEqual({ "errors", "deployments", "orders" })
		expect(s.checks[3].value).toBe("1")
		expect(s.checks[3].threshold).toBe("error ≥ 10")
		expect(s.checks[3].at).toBe(NOW)
		Model.record(
			c,
			spec("hourly"),
			Checks.evaluate(spec("hourly"), nil, { kind = "query", message = "x" }, NOW, nil)
		)
		expect(#Model.summary(c, SPECS, NOW, 120).checks).toBe(4)
	end)

	it("survives the kv round trip and rejects anything else stored under its key", function()
		local c = conn()
		allOk(c, NOW)
		local s = Model.summary(c, SPECS, NOW, 120)
		expect(Model.decode(s) ~= nil).toBe(true)
		expect(Model.decode({ v = 99 })).toBeNil()
		expect(Model.decode("x")).toBeNil()
		expect(Model.decode(nil)).toBeNil()
	end)

	it("collects badges per account for the status line", function()
		local c = conn()
		allOk(c, NOW)
		Model.record(c, spec("errors"), Checks.evaluate(spec("errors"), ERRORS_BAD, nil, NOW, nil))
		local badges = Model.badges({ Model.summary(c, SPECS, NOW, 120) })
		expect(badges["1234567_SB1"]).toBe("3 err/1h")
		expect(Model.badges({})["1234567_SB1"]).toBeNil()
	end)
end)

describe("toast on a new problem", function()
	it("toasts once when a healthy connection goes bad", function()
		expect(Model.shouldToast("ok", "error")).toBe(true)
		expect(Model.shouldToast("warn", "failed")).toBe(true)
		expect(Model.shouldToast("error", "error")).toBe(false)
		expect(Model.shouldToast("error", "failed")).toBe(false)
	end)

	it("stays quiet on startup and for credentials that were never stored", function()
		expect(Model.shouldToast(nil, "error")).toBe(false)
		expect(Model.shouldToast("pending", "error")).toBe(false)
		expect(Model.shouldToast("ok", "not_connected")).toBe(false)
	end)

	it("toasts again after the connection recovered and broke once more", function()
		local seq = { "ok", "error", "ok", "error" }
		local toasts = 0
		local prev: Model.ConnState? = nil
		for _, s in seq do
			if Model.shouldToast(prev, s :: Model.ConnState) then
				toasts += 1
			end
			prev = s :: Model.ConnState
		end
		expect(toasts).toBe(2)
	end)
end)

return nil
