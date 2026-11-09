--!strict
-- The execution log view's "Inspect" chip and `i` key.
local Config = require("../../../plugin/lib/config")
local InspectLink = require("../../../plugin/lib/inspector/link")
local State = require("../../../plugin/lib/monitor/logs/state")
local View = require("../../../plugin/lib/monitor/logs/view")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CONFIG = [[{
	"accounts": [ { "id": "sb", "label": "SB1", "account_id": "1234567_SB1" } ],
	"connections": [ { "id": "sb-rest", "account": "sb", "auth": "tba", "transport": "rest" } ],
	"monitor": { "log_poll_seconds": 15, "log_title_json": true }
}]]

local cfg = Config.parse(CONFIG, json.decode)
local env: State.Env = { decode = json.decode, null = json.null }

local function row(id: string, title: string, detail: string): any
	return {
		internalid = id,
		logged = "2026-10-08 22:15:4" .. id,
		type = "AUDIT",
		title = title,
		detail = detail,
		scripttype = "3561",
		scriptid = "customscript_acme_sync",
		scriptname = "Acme sync",
	}
end

local function loaded(rows: { any }): State.State
	local s, effects = State.init({}, nil, cfg, env)
	local q: State.Effect? = nil
	for _, e in effects do
		if e.t == "query" then
			q = e
		end
	end
	return State.update(
		s,
		{ t = "result", req = (q :: State.Effect).req, rows = rows, truncated = false, at = "22:16" }
	)
end

local function texts(node: any, acc: { string }): { string }
	if type(node) == "table" then
		local p = node.p
		if type(p) == "table" and type(p.text) == "string" then
			table.insert(acc, p.text)
		end
		for _, c in node.c or {} do
			texts(c, acc)
		end
	end
	return acc
end

describe("inspecting a record from the execution log", function()
	it("offers the record a selected log line mentions and opens it on the log's connection", function()
		local s = loaded({ row("1", "order.sync", '{"recordType":"salesorder","id":123}') })
		local dock = View.view((State.update(s, { t = "action", act = "detail" }))).dock
		expect(table.concat(texts(dock, {}), "\n")).toContain("Inspect Sales order #123")
		local _, effects = State.update(s, { t = "key", key = { name = "i", text = "i" } })
		expect(effects).toEqual({
			{ t = "inspect", url = "tern-netsuite://inspect?connection=sb-rest&type=salesorder&id=123" },
		})
		-- The host turns it into a start grant: only the plugin's own chip starts reading.
		local start = InspectLink.grantStart(effects[1].url :: string, nil, InspectLink.newId("t", 1), 1)
		expect(start ~= nil).toBe(true)
	end)

	it("offers nothing for a line that mentions no record", function()
		local s = loaded({ row("2", "suiteql:exec.done", '{"count":3}') })
		local dock = View.view((State.update(s, { t = "action", act = "detail" }))).dock
		expect((string.find(table.concat(texts(dock, {}), "\n"), "Inspect", 1, true))).toBeNil()
		local _, effects = State.update(s, { t = "action", act = "inspect" })
		expect(#effects).toBe(0)
	end)
end)

return nil
