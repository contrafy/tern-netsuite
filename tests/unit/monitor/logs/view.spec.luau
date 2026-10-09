--!strict
local Config = require("../../../../plugin/lib/config")
local Encoding = require("../../../../plugin/lib/ns/encoding")
local State = require("../../../../plugin/lib/monitor/logs/state")
local View = require("../../../../plugin/lib/monitor/logs/view")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function config(titleJson: boolean): Config.Config
	return (
		Config.parse(
			string.format(
				[[{
	"accounts": [
		{ "id": "sb", "label": "SB1", "account_id": "1234567_SB1" },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "production": true }
	],
	"connections": [
		{ "id": "sb-rest", "account": "sb", "auth": "tba", "transport": "rest" },
		{ "id": "prod-rest", "account": "prod", "auth": "tba", "transport": "rest" }
	],
	"monitor": { "log_title_json": %s }
}]],
				tostring(titleJson)
			),
			json.decode
		)
	)
end

local env: State.Env = { decode = json.decode, null = json.null }
local rows = json.decode(fixtures.read("monitor/logs/restlet-rows.json"))

local function key(name: string): State.Key
	return { name = name, text = name, ctrl = false, alt = false, shift = false, meta = false } :: any
end

local function loaded(args: { string }?, titleJson: boolean?): State.State
	local s, effects = State.init(args or {}, nil, config(titleJson ~= false), env)
	local req = 0
	for _, e in effects do
		if e.t == "query" then
			req = e.req :: number
		end
	end
	return (State.update(s, { t = "result", req = req, rows = rows, at = "22:16:10" }))
end

local function text(v: any): string
	return Encoding.json(v)
end

describe("the execution log view", function()
	it("labels a production connection so nobody mistakes whose logs these are", function()
		local v = text(View.view(loaded({ "connection=prod-rest" })))
		expect(v).toContain("PROD")
		expect(v).toContain("prod-rest")
	end)

	it("shows rows newest first with their level, script and title", function()
		local v = text(View.view(loaded()))
		expect(v).toContain("SuiteQL RESTlet")
		expect(v).toContain("JS_EXCEPTION")
		local newest = string.find(v, "sync failed", 1, true) :: number
		local oldest = string.find(v, "exec.done", 1, true) :: number
		expect(newest < oldest).toBe(true)
	end)

	it("highlights the namespace of namespace:event titles when JSON titles are on", function()
		local v = text(View.view(loaded()))
		expect(v).toContain('{"s":"accent","t":"suiteql"}')
		local plain = text(View.view(loaded(nil, false)))
		expect(plain).toContain("suiteql:exec.done")
		expect((string.find(plain, '{"s":"accent","t":"suiteql"}', 1, true))).toBeNil()
	end)

	it("shows the selected row's JSON detail as a tree in the dock", function()
		local s = loaded()
		for _ = 1, 3 do
			s = State.update(s, { t = "key", key = key("j") })
		end
		s = State.update(s, { t = "key", key = key("enter") })
		local v = View.view(s)
		expect(v.dock ~= nil).toBe(true)
		local dock = text(v.dock)
		expect(dock).toContain('"k":"tree"')
		expect(dock).toContain("SSS_DUPLICATE_ALIAS")
	end)

	it("shows a raw detail as text when it is not JSON or JSON titles are off", function()
		local s = loaded(nil, false)
		for _ = 1, 3 do
			s = State.update(s, { t = "key", key = key("j") })
		end
		s = State.update(s, { t = "key", key = key("enter") })
		local dock = text(View.view(s).dock)
		expect((string.find(dock, '"k":"tree"', 1, true))).toBeNil()
		expect(dock).toContain("SSS_DUPLICATE_ALIAS")
	end)

	it("points at the connect command when credentials are missing", function()
		local s, effects = State.init({}, nil, config(true), env)
		local req = (effects[1] :: any).req
		s = State.update(s, {
			t = "result",
			req = req,
			err = { kind = "auth", message = "no stored credentials", code = "TNS_NO_CREDENTIALS" },
		})
		local v = text(View.view(s))
		expect(v).toContain("Tern NetSuite: Connect account")
		expect(v).toContain('"click":"connect"')
	end)

	it("tells the user how to set up a connection when there is none", function()
		local s = State.init({}, nil, (Config.parse("{}", json.decode)), env)
		expect(text(View.view(s))).toContain("connections[]")
	end)

	it("names the filter and how many rows it hides", function()
		local s = loaded()
		s = State.update(s, { t = "key", key = key("l") })
		s = State.update(s, { t = "key", key = key("l") })
		expect(text(View.view(s))).toContain("3 of 7")
	end)

	it("says when old rows were dropped from the buffer", function()
		local s = loaded()
		local many = {}
		for i = 1, State.CAP + 5 do
			table.insert(many, {
				internalid = 6000000 + i,
				logged = string.format("2026-10-09 %02d:%02d:%02d", i // 3600, (i // 60) % 60, i % 60),
				type = "DEBUG",
				title = "bulk",
				detail = "",
			})
		end
		local reloaded, effects = State.update(s, { t = "key", key = key("r") })
		local req = 0
		for _, e in effects do
			if e.t == "query" then
				req = e.req :: number
			end
		end
		s = State.update(reloaded, { t = "result", req = req, rows = many, at = "x" })
		expect(text(View.view(s))).toContain("5 older rows dropped")
	end)

	it("puts the rows in a list that fills the pane and keeps the selection in view", function()
		local s = loaded()
		local main = View.view(s).main :: any
		local list: any = nil
		for _, n in main.c do
			if n.p and n.p.key == "rows" then
				list = n
			end
		end
		expect(list.p.role).toBe("tern-netsuite.scroll")
		local visible = State.visible(s)
		expect(list.p.selected).toBe("main.rows.r" .. visible[State.selectedIndex(s, visible)].id)
		expect(list.p.max.lines).toBe(State.MAX_RENDER_ROWS)
	end)

	it("draws more rows than the reported height, since Tern 0.7.0 reports 80x24 for any pane", function()
		local many = {}
		for i = 1, 100 do
			table.insert(many, {
				internalid = 6000000 + i,
				logged = string.format("2026-10-09 00:%02d:%02d", i // 60, i % 60),
				type = "DEBUG",
				title = "bulk",
				detail = "",
			})
		end
		local reloaded, effects = State.update(loaded(), { t = "key", key = key("r") })
		local req = 0
		for _, e in effects do
			if e.t == "query" then
				req = e.req :: number
			end
		end
		local s = State.update(reloaded, { t = "result", req = req, rows = many, at = "x" })
		s = State.update(s, { t = "resize", height = 24, width = 80 })
		local list: any = nil
		for _, n in (View.view(s).main :: any).c do
			if n.p and n.p.key == "rows" then
				list = n
			end
		end
		expect(#list.c).toBe(100)
	end)

	it("keeps every row on one line of a narrow block so the visible window stays accurate", function()
		for _, cols in { 60, 100, 200 } do
			local s = State.update(loaded(), { t = "resize", height = 40, width = cols })
			local main = View.view(s).main :: any
			local rowsNode: any = nil
			for _, n in main.c do
				if n.p and n.p.key == "rows" then
					rowsNode = n
				end
			end
			expect(rowsNode ~= nil).toBe(true)
			for _, line in rowsNode.c do
				local chars = 0
				for _, span in line.p.spans do
					chars += utf8.len(span.t) :: number
				end
				expect(chars <= cols - 4).toBe(true)
			end
		end
	end)

	it("titles the pane with the connection", function()
		expect(View.title(loaded())).toContain("sb-rest")
	end)
end)

return nil
