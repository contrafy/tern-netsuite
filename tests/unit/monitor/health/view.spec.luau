--!strict
local Checks = require("../../../../plugin/lib/monitor/health/checks")
local Config = require("../../../../plugin/lib/config")
local Model = require("../../../../plugin/lib/monitor/health/model")
local View = require("../../../../plugin/lib/monitor/health/view")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CFG = Config.parse(
	[[{
	"accounts": [{"id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"]}],
	"connections": [{"id": "demo-sb", "account": "sb", "auth": "tba", "transport": "rest"}]
}]],
	json.decode
)
local SPECS = Checks.specs(CFG)
local NOW = 2000000

-- All visible text of a node tree, in order.
local function texts(node: any, out: { string }?): string
	local acc = out or {}
	if type(node) == "table" then
		for k, v in node do
			if (k == "t" or k == "text" or k == "label") and type(v) == "string" then
				table.insert(acc, v)
			end
		end
		for _, v in node do
			if type(v) == "table" then
				texts(v, acc)
			end
		end
	end
	return table.concat(acc, " ")
end

local function find(node: any, kind: string): any
	if type(node) ~= "table" then
		return nil
	end
	if node.k == kind then
		return node
	end
	for _, v in node do
		local hit = find(v, kind)
		if hit then
			return hit
		end
	end
	return nil
end

local function rows(path: string): { any }
	local doc = json.decode(fixtures.read("monitor/health/" .. path))
	return doc.items or doc.rows
end

local function polled(): Model.Summary
	local c = Model.conns(CFG)[1]
	for _, s in SPECS do
		local data = if s.kind == "errors"
			then rows("errors-rest.json")
			elseif s.kind == "hourly" then rows("hourly-rest.json")
			elseif s.kind == "last_error" then rows("last-error-restlet.json")
			else rows("deployments-rest.json")
		Model.record(c, s, Checks.evaluate(s, data, nil, NOW - 90, c.clock))
	end
	return Model.summary(c, SPECS, NOW - 60, 120)
end

local function entry(summary: Model.Summary?): View.Entry
	return { id = "demo-sb", label = "SB1", summary = summary }
end

describe("health dashboard", function()
	it("tells a user without credentials that the account is not connected and how to fix it", function()
		local c = Model.conns(CFG)[1]
		Model.disconnect(c, 'no stored consumer key for connection "demo-sb"')
		local v = View.render({ entries = { entry(Model.summary(c, SPECS, NOW, 120)) }, now = NOW })
		local text = texts(v.main)
		expect(text).toContain("not connected")
		expect(text).toContain("Connect account")
	end)

	it("says the first poll is still pending rather than showing an empty page", function()
		local text = texts(View.render({ entries = { entry(nil) }, now = NOW }).main)
		expect(text).toContain("waiting for the first poll")
	end)

	it("points to the config when no connection is configured", function()
		local text = texts(View.render({ entries = {}, now = NOW }).main)
		expect(text).toContain("connections")
	end)

	it("shows each check's value, threshold and age, the error sparkline, deployments and the last error", function()
		local v = View.render({ entries = { entry(polled()) }, now = NOW })
		local text = texts(v.main)
		expect(text).toContain("5 in 1 h · 543 in 24 h")
		expect(text).toContain("error ≥ 1 in 1 h")
		expect(text).toContain("1 min ago")
		expect(text).toContain("customdeploy_demo_test")
		expect(text).toContain("restlet.error")
		expect(text).toContain("Demo SuiteQL RESTlet")
		local chart = find(v.main, "chart")
		expect(chart ~= nil).toBe(true)
		expect(chart.p.kind).toBe("spark")
		expect(#chart.p.series).toBe(24)
		expect(chart.p.series[24].value).toBe(5)
	end)

	it("lists the keys it answers to", function()
		local text = texts(View.render({ entries = {}, now = NOW }).dock)
		expect(text).toContain("refresh")
		expect(text).toContain("close")
	end)

	it("titles the pane with the worst state so a glance at the tab is enough", function()
		expect(View.title({ entry(polled()) })).toBe("NetSuite health: error")
		expect(View.title({})).toBe("NetSuite health")
	end)

	it("never emits a node with empty props, which encode as a JSON array and blank the whole block", function()
		local function check(node: any)
			if type(node) ~= "table" then
				return
			end
			if type(node.k) == "string" then
				expect(node.p ~= nil and next(node.p) ~= nil).toBe(true)
			end
			for _, v in node do
				check(v)
			end
		end
		local v = View.render({ entries = { entry(polled()) }, now = NOW })
		check(v.main)
		check(v.dock)
	end)
end)

return nil
