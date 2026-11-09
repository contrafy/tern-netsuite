--!strict
local Config = require("../../../plugin/lib/config")
local Errors = require("../../../plugin/lib/ns/errors")
local State = require("../../../plugin/lib/console/state")
local View = require("../../../plugin/lib/console/view")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CONFIG = [[{
	"accounts": [
		{ "id": "sb", "label": "SB1", "account_id": "1234567_SB1" },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "production": true }
	],
	"connections": [
		{ "id": "sb-restlet", "account": "sb", "auth": "tba", "transport": "restlet",
		  "restlet": { "script": "customscript_acme_suiteql", "deploy": "customdeploy_acme_suiteql" } },
		{ "id": "prod-rest", "account": "prod", "auth": "tba", "transport": "rest" }
	],
	"console": { "max_rows": 2 }
}]]

local cfg = Config.parse(CONFIG, json.decode)
local env: State.Env = { null = json.null }

local function key(name: string, text: string?, mods: { [string]: boolean }?): State.Key
	local k: { [string]: any } = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
	for m, v in (mods or {}) :: { [string]: boolean } do
		k[m] = v
	end
	return k :: any
end

local function find(node: any, k: string): any
	if type(node) ~= "table" then
		return nil
	end
	if node.p and node.p.key == k then
		return node
	end
	for _, c in node.c or {} do
		local f = find(c, k)
		if f then
			return f
		end
	end
	return nil
end

-- Every text the node tree shows, joined.
local function text(node: any): string
	local out: { string } = {}
	local function walk(n: any)
		if type(n) ~= "table" then
			return
		end
		local p = n.p or {}
		if p.spans then
			for _, s in p.spans do
				table.insert(out, s.t)
			end
		end
		if type(p.text) == "string" then
			table.insert(out, p.text)
		end
		for _, part in { p.head, p.meta } do
			if type(part) == "table" then
				for _, s in part do
					table.insert(out, s.t)
				end
			end
		end
		if p.items then
			for _, item in p.items do
				for _, side in { item.k, item.v } do
					for _, s in side or {} do
						table.insert(out, s.t)
					end
				end
			end
		end
		for _, c in n.c or {} do
			walk(c)
		end
	end
	walk(node)
	return table.concat(out, " ")
end

local function run(s: State.State, conn: string, sql: string, rows: { any }, truncated: boolean?): State.State
	s = State.update(s, { t = "action", act = "conn", value = conn })
	s = State.update(s, { t = "key", key = key("paste", sql) })
	local _, effects = State.update(s, { t = "key", key = key("enter", nil, { ctrl = true }) })
	s = State.update(s, { t = "key", key = key("enter", nil, { ctrl = true }) })
	local req = s.inflight
	expect(#effects > 0).toBe(true)
	return State.update(s, { t = "result", req = req, rows = rows, truncated = truncated, pages = 1, elapsed = 1250 })
end

local function start(): State.State
	return (State.init({}, nil, cfg, env, { history = {}, saved = {} }))
end

describe("console view", function()
	it("marks a production connection and every result from it with a red PROD badge", function()
		local s = run(start(), "prod-rest", "SELECT id FROM customer", { { id = "1" } })
		local v = View.view(s)
		expect(find(v.main, "prod").p.text).toBe("PROD")
		expect(find(v.main, "prod").p.tone).toBe("error")
		expect(find(v.main, "rprod").p.tone).toBe("error")
		expect(find(v.main, "rconn").p.tone).toBe("error")
		s = State.update(s, { t = "action", act = "conn", value = "sb-restlet" })
		v = View.view(s)
		expect(find(v.main, "prod")).toBeNil()
		expect(find(v.main, "rprod").p.text).toBe("PROD")
	end)

	it("shows row count, timing and that the row cap cut the result", function()
		local s = run(start(), "sb-restlet", "SELECT id FROM customer", { { id = 1 }, { id = 2 } }, true)
		local main = View.view(s).main
		expect(text(find(main, "rstats"))).toBe("2 rows · 1.25 s")
		expect(find(main, "rtrunc").p.text).toBe("truncated: first 2 rows (console.max_rows)")
	end)

	it("shows RESTlet values as typed and REST strings as sent, NULL dimmed", function()
		local rows = json.decode(fixtures.read("console/restlet-customers.json")).rows
		local sql = "SELECT id, companyname, balance, email, isinactive FROM customer"
		local s = run(start(), "sb-restlet", sql, rows)
		-- Cells are spans 2, 4, 6, ... (separators between them).
		local second = find(View.view(s).main, "p2").p.spans
		expect(second[2].t).toBe("102") -- a number: right-aligned in its column
		expect(second[6].t).toBe("      0")
		expect(second[10]).toEqual({ t = "true      ", s = "accent" })
		local first = find(View.view(s).main, "p1").p.spans
		expect(first[8].t).toBe("null" .. string.rep(" ", 18))
		expect(first[8].s).toBe("muted") -- NULL stays dim, even in the selected row
		s = run(s, "prod-rest", sql, { { id = "101", balance = "1250.50", isinactive = "F" } })
		local rest = find(View.view(s).main, "p1").p.spans
		expect(rest[6]).toEqual({ t = "1250.50", s = "strong" })
		expect(rest[10].t).toBe("F         ")
	end)

	it("draws at most 200 rows around the selection however many came back", function()
		local rows = {}
		for i = 1, 1000 do
			rows[i] = { id = tostring(i) }
		end
		local s = run(start(), "sb-restlet", "SELECT id FROM customer", rows)
		s = State.update(s, { t = "key", key = key("tab") })
		s = State.update(s, { t = "key", key = key("G", "G", { shift = true }) })
		local main = View.view(s).main
		local list = find(main, "rows")
		expect(#list.c).toBe(200)
		expect(list.p.selected).toBe("main.rows.p1000")
		expect(text(find(main, "above"))).toBe("↑ 800 more (k, g)")
	end)

	it("explains a refused statement instead of sending it", function()
		local s = start()
		s = State.update(s, { t = "key", key = key("paste", "UPDATE customer SET x = 1") })
		s = State.update(s, { t = "key", key = key("enter", nil, { ctrl = true }) })
		local card = find(View.view(s).main, "errcard")
		expect(text(card)).toContain("Not run: the console is read-only")
		expect(text(card)).toContain("only SELECT or WITH queries are allowed, not UPDATE")
		expect(text(card)).toContain("one SELECT or WITH query at a time")
	end)

	it("offers Connect account for credential errors", function()
		local s = start()
		s = State.update(s, { t = "key", key = key("paste", "SELECT 1 FROM dual") })
		s = State.update(s, { t = "key", key = key("enter", nil, { ctrl = true }) })
		s = State.update(s, {
			t = "result",
			req = s.inflight,
			err = Errors.new("auth", 'no credentials are stored for connection "sb-restlet"', Errors.NO_CREDENTIALS),
		})
		local main = View.view(s).main
		expect(find(main, "connect").p.actions.click).toBe("connect")
	end)

	it("inspects one row with each value's type and record buttons", function()
		local rows = json.decode(fixtures.read("console/restlet-customers.json")).rows
		local s = run(start(), "sb-restlet", "SELECT id, companyname, balance, email, isinactive FROM customer", rows)
		s = State.update(s, { t = "action", act = "row", value = "1" })
		local dock = View.view(s).dock
		local shown = text(dock)
		expect(shown).toContain("balance 1250.5   number")
		expect(shown).toContain("email null   null")
		expect(find(dock, "insp1").p.text).toBe("Inspect customer 101")
	end)

	it("lists folder files by their path in the folder, the folder when several, and what was not listed", function()
		local s = State.update(start(), { t = "key", key = key("o", "o", { ctrl = true }) })
		s = State.update(s, {
			t = "listed",
			saved = {},
			files = {
				{ path = "/tmp/acme/sql/orders/open.sql", name = "open.sql", rel = "orders/open.sql", folder = "sql" },
				{
					path = "/Users/demo/team/c.sql",
					name = "c.sql",
					rel = "c.sql",
					title = "Customers",
					folder = "~/team",
				},
			},
			problems = { "3 more .sql files not listed: only the first 500 are" },
		})
		local main = View.view(s).main
		expect(text(find(main, "p1"))).toBe("›  file    open.sql   orders/open.sql   in sql")
		expect(text(find(main, "p2"))).toBe("   file    Customers   c.sql   in ~/team")
		expect(text(find(main, "pp1"))).toBe("3 more .sql files not listed: only the first 500 are")
	end)
end)

return nil
