--!strict
local Config = require("../../../plugin/lib/config")
local Errors = require("../../../plugin/lib/ns/errors")
local State = require("../../../plugin/lib/inspector/state")
local View = require("../../../plugin/lib/inspector/view")
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
		{ "id": "sb-rest", "account": "sb", "auth": "tba", "transport": "rest" },
		{ "id": "prod-rest", "account": "prod", "auth": "tba", "transport": "rest" }
	]
}]]

local cfg = Config.parse(CONFIG, json.decode)
local env: State.Env = { null = json.null }

-- Every text, badge text and click action in a view tree.
local function flatten(node: any, out: { string }?): { string }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	local p = node.p
	if type(p) == "table" then
		if type(p.text) == "string" then
			table.insert(acc, p.text)
		end
		if type(p.spans) == "table" then
			local parts: { string } = {}
			for _, sp in p.spans do
				table.insert(parts, sp.t)
			end
			table.insert(acc, table.concat(parts))
		end
		if type(p.head) == "table" then
			for _, sp in p.head do
				table.insert(acc, sp.t)
			end
		end
		if type(p.actions) == "table" and type(p.actions.click) == "string" then
			table.insert(acc, "@" .. p.actions.click)
		end
	end
	for _, c in node.c or {} do
		flatten(c, acc)
	end
	return acc
end

local function texts(v: { main: any, dock: any? }): string
	local all = flatten(v.main)
	if v.dock then
		flatten(v.dock, all)
	end
	return table.concat(all, "\n")
end

local function first(effects: { State.Effect }, part: string): State.Effect
	for _, e in effects do
		if e.part == part then
			return e
		end
	end
	error("no " .. part)
end

local function loaded(args: { string }): State.State
	local s, effects = State.init(args, nil, cfg, env)
	s = State.update(s, {
		t = "result",
		req = first(effects, "record").req,
		rows = json.decode(fixtures.read("inspector/salesorder-rest.json")),
	})
	return s
end

describe("record inspector view", function()
	it("marks a production connection with a PROD badge", function()
		local out = texts(View.view(loaded({ "connection=prod-rest", "type=salesorder", "id=123" })))
		expect(out).toContain("PROD")
		expect(View.title(loaded({ "connection=prod-rest", "type=salesorder", "id=123" }))).toContain("PROD")
		local sb = texts(View.view(loaded({ "connection=sb-rest", "type=salesorder", "id=123" })))
		expect((string.find(sb, "\nPROD\n", 1, true))).toBeNil()
	end)

	it("shows the record's title, the Open in NetSuite chip and the tabs", function()
		local out = texts(View.view(loaded({ "connection=sb-rest", "type=transaction", "id=123" })))
		expect(out).toContain("Sales order  SO-1001  #123")
		expect(out).toContain("@open-ui")
		expect(out).toContain("1 Fields (10)")
		expect(out).toContain("2 System notes (…)")
	end)

	it("explains a held link and offers only start and close", function()
		local s = State.init({ "connection=prod-rest", "type=customer", "id=42", "hold=1" }, nil, cfg, env)
		local out = texts(View.view(s))
		expect(out).toContain("Inspect a NetSuite record?")
		expect(out).toContain("nothing is read until you press Enter")
		expect(out).toContain("PROD")
		expect(out).toContain("@start")
		expect((string.find(out, "@open-ui", 1, true))).toBeNil()
	end)

	it("shows a failed read inline with what to do", function()
		local s, effects = State.init({ "connection=sb-rest", "type=invoice", "id=9" }, nil, cfg, env)
		s = State.update(s, {
			t = "result",
			req = first(effects, "record").req,
			err = Errors.new("permission", "INSUFFICIENT_PERMISSION: no access"),
		})
		local out = texts(View.view(s))
		expect(out).toContain("The record cannot be read")
		expect(out).toContain("INSUFFICIENT_PERMISSION: no access")
		expect(out).toContain("SuiteQL access")
	end)

	it("keeps long values on one line in the list and shows them whole in the dock", function()
		local s = loaded({ "connection=sb-rest", "type=salesorder", "id=123" })
		for _ = 1, 20 do
			local nextS = State.update(s, { t = "key", key = { name = "j", text = "j" } })
			local f = State.visibleFields(nextS)[State.selection(nextS, "fields")]
			s = nextS
			if f.column == "memo" then
				break
			end
		end
		local v = View.view(s)
		expect(texts({ main = v.main })).toContain("Acme storefront order ⏎ second line")
		expect(texts({ main = { c = { v.dock } } })).toContain("Acme storefront order\nsecond line")
	end)

	it("asks for connections when none are configured", function()
		local empty = Config.parse("{}", json.decode)
		local s = State.init({}, nil, empty, env)
		expect(texts(View.view(s))).toContain("No connections are configured")
	end)

	it("shows a failed system notes read without a Loading line that never ends", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = State.update(s, {
			t = "result",
			req = first(effects, "record").req,
			rows = json.decode(fixtures.read("inspector/salesorder-rest.json")),
		})
		s = State.update(
			s,
			{ t = "result", req = first(effects, "notes").req, err = Errors.new("query", "Search error") }
		)
		s = State.update(s, { t = "key", key = { name = "2", text = "2" } })
		local out = texts(View.view(s))
		expect(out).toContain("System notes could not be read")
		expect((string.find(out, "Loading", 1, true))).toBeNil()
	end)

	it("labels a system note's field and names its type", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = State.update(s, {
			t = "result",
			req = first(effects, "record").req,
			rows = json.decode(fixtures.read("inspector/salesorder-rest.json")),
		})
		s = State.update(s, {
			t = "result",
			req = first(effects, "notes").req,
			rows = json.decode(fixtures.read("inspector/notes-restlet.json")),
		})
		s = State.update(s, { t = "key", key = { name = "2", text = "2" } })
		local out = texts(View.view(s))
		-- the dock shows the selected note's field with its label
		expect(out).toContain("Document Status (TRANDOC.KSTATUS)")
		expect(out).toContain("- Pending Approval\n+ Pending Fulfillment")
		expect(out).toContain("Change")
	end)

	it("shows a standard field's label with its column and where the labels came from", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = State.update(s, {
			t = "result",
			req = first(effects, "record").req,
			rows = json.decode(fixtures.read("inspector/salesorder-rest.json")),
		})
		s = State.update(s, {
			t = "result",
			req = first(effects, "std").req,
			labels = { tranid = "Order #" },
			fetched = os.time(),
			cached = true,
		})
		local out = texts(View.view(s))
		expect(out).toContain("Order # (tranid)")
		expect(out).toContain("NetSuite's metadata catalog")
		expect(out).toContain("l refreshes")
	end)

	it("says why standard fields show column names when the labels could not be read", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = State.update(s, {
			t = "result",
			req = first(effects, "record").req,
			rows = json.decode(fixtures.read("inspector/salesorder-rest.json")),
		})
		s = State.update(s, {
			t = "result",
			req = first(effects, "std").req,
			err = Errors.new("permission", "INSUFFICIENT_PERMISSION: REST Web Services"),
		})
		local out = texts(View.view(s))
		expect(out).toContain("Standard field labels are unavailable")
		expect(out).toContain("REST Web Services")
	end)

	it("tells the user shift+enter opens a related record in a new pane", function()
		expect(texts(View.view(loaded({ "connection=sb-rest", "type=salesorder", "id=123" })))).toContain("shift+enter")
	end)
end)

return nil
