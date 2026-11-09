--!strict
local Config = require("../../../plugin/lib/config")
local Errors = require("../../../plugin/lib/ns/errors")
local State = require("../../../plugin/lib/inspector/state")
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

local function rows(name: string): { any }
	return json.decode(fixtures.read("inspector/" .. name))
end

local function queries(effects: { State.Effect }): { [string]: State.Effect }
	local out: { [string]: State.Effect } = {}
	for _, e in effects do
		if e.t == "query" then
			expect(out[e.part :: string]).toBeNil()
			out[e.part :: string] = e
		end
	end
	return out
end

local function partsOf(effects: { State.Effect }): { string }
	local out: { string } = {}
	for _, e in effects do
		if e.t == "query" then
			table.insert(out, e.part :: string)
		end
	end
	table.sort(out)
	return out
end

local function answer(
	s: State.State,
	e: State.Effect,
	r: { any }?,
	err: Errors.NsError?
): (State.State, { State.Effect })
	return State.update(s, { t = "result", req = e.req, rows = r, err = err })
end

local function key(s: State.State, name: string, text: string?): (State.State, { State.Effect })
	return State.update(s, { t = "key", key = { name = name, text = text } })
end

local function metadataOf(effects: { State.Effect }): State.Effect?
	local found: State.Effect? = nil
	for _, e in effects do
		if e.t == "metadata" then
			expect(found).toBeNil()
			found = e
		end
	end
	return found
end

-- A sales order read in full from the fixtures.
local function loadedOrder(): State.State
	local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
	local q = queries(effects)
	s, effects = answer(s, q.record, rows("salesorder-rest.json"))
	local std = metadataOf(effects) :: State.Effect
	q = queries(effects)
	s = State.update(s, { t = "result", req = std.req, labels = {}, fetched = 1000 })
	local after: { State.Effect }
	s, after = answer(s, q.labels, rows("labels-rest.json"))
	s = answer(s, queries(after).display, rows("display-rest.json"))
	s = answer(s, q.notes, rows("notes-restlet.json"))
	s = answer(s, q.lines, rows("lines-rest.json"))
	s = answer(s, q.children, rows("children-rest.json"))
	s = answer(s, q.from, {})
	return s
end

describe("record inspector state", function()
	it("opens from the palette with the input focused and reads nothing yet", function()
		local s, effects = State.init({}, nil, cfg, env)
		expect(s.editing).toBe(true)
		expect(#effects).toBe(1)
		expect(effects[1].t).toBe("focus")
		expect(s.cur).toBeNil()
	end)

	it("reads the record first, then labels, notes, lines and linked transactions in parallel", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		local q = queries(effects)
		expect(q.record.sql).toBe("SELECT * FROM transaction WHERE id = ?")
		expect(q.record.connection).toBe("sb-rest")
		local next: { State.Effect }
		s, next = answer(s, q.record, rows("salesorder-rest.json"))
		expect(partsOf(next)).toEqual({ "children", "from", "labels", "lines", "notes" })
		expect(queries(next).notes.params).toEqual({ 123, -30 })
	end)

	it("links a fulfillment back to the order it was created from", function()
		local s, effects = State.init({ "connection=sb-rest", "type=itemfulfillment", "id=130" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, { { id = "130", type = "ItemShip", tranid = "IF-2001" } })
		local q = queries(effects)
		expect(q.from.params).toEqual({ 130 })
		s = answer(s, q.from, rows("createdfrom-rest.json"))
		local back = State.related(s)[1]
		expect(back.label).toBe("Created from")
		expect(back.id).toBe("123")
		expect(back.name).toBe("Sales Order #SO-1001")
		s = key(s, "3", "3")
		local _, opened = key(s, "enter")
		expect(queries(opened).record.sql).toBe("SELECT * FROM transaction WHERE id = ?")
	end)

	it("re-reads a generic entity from its own table once the row names its type, for every field", function()
		local s, effects = State.init({ "connection=sb-rest", "type=entity", "id=42" }, nil, cfg, env)
		s, effects =
			answer(s, queries(effects).record, { { id = "42", type = "CustJob", entityid = "Acme Retail Co" } })
		local q = queries(effects)
		expect(partsOf(effects)).toEqual({ "record" })
		expect(q.record.sql).toBe("SELECT * FROM customer WHERE id = ?")
		local cur = s.cur :: State.Inspection
		expect((cur.kind :: any).record).toBe("customer")
		s, effects = answer(s, q.record, { { id = "42", entityid = "Acme Retail Co", companyname = "Acme Retail Co" } })
		expect(queries(effects).txns ~= nil).toBe(true)
		expect((State.uiUrl(s))).toBe("https://1234567-sb1.app.netsuite.com/app/common/entity/custjob.nl?id=42")
	end)

	it("finishes every part of an entity re-read from its own table, system notes included", function()
		local s, effects = State.init({ "connection=sb-rest", "type=entity", "id=42" }, nil, cfg, env)
		s, effects =
			answer(s, queries(effects).record, { { id = "42", type = "CustJob", entityid = "Acme Retail Co" } })
		s, effects = answer(s, queries(effects).record, { { id = "42", entityid = "Acme Retail Co", parent = "7" } })
		expect(queries(effects).notes.params).toEqual({ 42, -2, -9 })
		-- answer every query, and the ones they lead to, in the order issued
		local queue = table.clone(effects)
		while #queue > 0 do
			local e = table.remove(queue, 1) :: State.Effect
			local more: { State.Effect } = {}
			if e.t == "query" then
				s, more = answer(s, e, if e.part == "notes" then rows("notes-restlet.json") else {})
			elseif e.t == "metadata" then
				s, more = State.update(s, { t = "result", req = e.req, labels = {} })
			end
			table.move(more, 1, #more, #queue + 1, queue)
		end
		expect(State.loading(s)).toBe(false)
		expect(State.count(s, "notes")).toBe(2)
	end)

	it("shows all four views of a fully loaded record", function()
		local s = loadedOrder()
		local cur = s.cur :: State.Inspection
		expect(State.loading(s)).toBe(false)
		expect(cur.title).toBe("SO-1001")
		expect(cur.labels.custbody_acme_box.label).toBe("Shipping box")
		expect(#(cur.notes :: { any })).toBe(2)
		-- entity, subsidiary, the custom box field, two line items and two child transactions
		expect(State.count(s, "related")).toBe(7)
		-- empty fields stay hidden until asked for
		expect(State.count(s, "fields")).toBe(10)
		s = key(s, "e", "e")
		expect(State.count(s, "fields")).toBe(11)
		expect((State.uiUrl(s))).toBe(
			"https://1234567-sb1.app.netsuite.com/app/accounting/transactions/salesord.nl?id=123"
		)
	end)

	it("opens the record's NetSuite page in the browser on o", function()
		local _, effects = key(loadedOrder(), "o", "o")
		expect(effects).toEqual({
			{
				t = "browse",
				url = "https://1234567-sb1.app.netsuite.com/app/accounting/transactions/salesord.nl?id=123",
			},
		})
	end)

	it("inspects a related record in place and goes back to the previous one", function()
		local s = key(loadedOrder(), "3", "3")
		expect(s.tab).toBe("related")
		local effects: { State.Effect }
		s, effects = key(s, "enter")
		local cur = s.cur :: State.Inspection
		expect(cur.ref.id).toBe("42")
		expect(queries(effects).record.sql).toBe("SELECT * FROM entity WHERE id = ?")
		expect(#s.history).toBe(1)
		s, effects = key(s, "b", "b")
		expect((s.cur :: State.Inspection).ref.id).toBe("123")
		expect(#s.history).toBe(0)
		expect(queries(effects).record ~= nil).toBe(true)
	end)

	it("ignores late results of an inspection the user already left", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		local old = queries(effects).record
		s = State.update(s, { t = "action", act = "input-focus" })
		s = State.update(s, { t = "key", key = { name = "u", ctrl = true } })
		for _, c in { "c", "u", "s", "t", "o", "m", "e", "r", ":", "4", "2" } do
			s = key(s, c, c)
		end
		s, effects = key(s, "enter")
		expect(queries(effects).record.sql).toBe("SELECT * FROM customer WHERE id = ?")
		local after = answer(s, old, rows("salesorder-rest.json"))
		expect(after).toBe(s)
	end)

	it("waits for Enter when opened from a plain link, then reads", function()
		local s, effects = State.init({ "type=customer", "id=42", "hold=1" }, nil, cfg, env)
		expect(s.held).toBe(true)
		expect(#effects).toBe(0)
		local same = key(s, "j", "j")
		expect(same).toBe(s)
		s, effects = key(s, "enter")
		expect(s.held).toBe(false)
		expect(queries(effects).record.params).toEqual({ 42 })
	end)

	it("reads a pasted URL on the connection of the URL's account, production included", function()
		local s, effects = State.init({}, nil, cfg, env)
		s = key(s, "paste", "https://1234567.app.netsuite.com/app/common/entity/custjob.nl?id=42")
		s, effects = key(s, "enter")
		expect((State.target(s) :: State.Target).id).toBe("prod-rest")
		expect((State.target(s) :: State.Target).production).toBe(true)
		expect(queries(effects).record.connection).toBe("prod-rest")
	end)

	it("refuses a URL for an account no connection reads instead of reading another account", function()
		local s = State.init({}, nil, cfg, env)
		s = key(s, "paste", "https://7654321.app.netsuite.com/app/common/entity/custjob.nl?id=42")
		local effects: { State.Effect }
		s, effects = key(s, "enter")
		expect(#effects).toBe(0)
		expect(s.problem).toContain("7654321")
	end)

	it("resolves a custom record URL's numeric type before reading the record", function()
		local s, effects = State.init({ "connection=sb-rest", "rectype=12", "id=5" }, nil, cfg, env)
		local q = queries(effects)
		expect(q.rectype.params).toEqual({ 12 })
		s, effects = answer(s, q.rectype, rows("customrecordtype-rest.json"))
		expect(queries(effects).record.sql).toBe("SELECT * FROM customrecord_acme_box WHERE id = ?")
		expect(s.input).toBe("customrecord_acme_box:5")
		s, effects = answer(s, queries(effects).record, rows("customrecord-rest.json"))
		expect(queries(effects).notes.params).toEqual({ 5, 12 })
		expect((State.uiUrl(s))).toBe(
			"https://1234567-sb1.app.netsuite.com/app/common/custom/custrecordentry.nl?rectype=12&id=5"
		)
	end)

	it("falls back to plain labels when the account rejects the field metadata join", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		local denied = Errors.new("query", "Unknown identifier 'fieldvaluetyperecord'")
		s, effects = answer(s, queries(effects).labels, nil, denied)
		local plain = queries(effects)["labels-plain"]
		expect(plain.sql).toContain("FROM customfield WHERE")
		s, effects = answer(s, plain, nil, Errors.new("permission", "no access"))
		expect((s.cur :: State.Inspection).errs["labels-plain"].kind).toBe("permission")
		-- names of the reference columns are still asked for
		expect(queries(effects).display ~= nil).toBe(true)
	end)

	it("reports a missing record and a failed read inline", function()
		local s, effects = State.init({ "connection=sb-rest", "type=invoice", "id=9" }, nil, cfg, env)
		local missing = answer(s, queries(effects).record, {})
		expect((missing.cur :: State.Inspection).missing).toBe(true)
		local failed = answer(s, queries(effects).record, nil, Errors.new("permission", "INSUFFICIENT_PERMISSION"))
		expect((failed.cur :: State.Inspection).errs.record.kind).toBe("permission")
		expect(State.loading(failed)).toBe(false)
	end)

	it("restores a started inspection after a reload without waiting for Enter again", function()
		local s = loadedOrder()
		local saved = State.save(s)
		local restored, effects = State.init({ "type=customer", "id=42", "hold=1" }, saved, cfg, env)
		expect(restored.held).toBe(false)
		expect(queries(effects).record ~= nil).toBe(true)
	end)

	it("names an unknown connection instead of silently using another", function()
		local s, effects = State.init({ "connection=nope", "type=customer", "id=42" }, nil, cfg, env)
		expect(#effects).toBe(0)
		expect(s.problem).toContain("nope")
	end)
end)

local STD = { tranid = "Order #", trandate = "Date", entity = "Customer", custbody_acme_box = "Box (schema)" }

describe("standard field labels", function()
	it("asks the metadata catalog of the specific record type once the record row names it", function()
		local s, effects = State.init({ "connection=sb-rest", "type=transaction", "id=123" }, nil, cfg, env)
		expect(metadataOf(effects)).toBeNil()
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		local m = metadataOf(effects) :: State.Effect
		expect(m.record).toBe("salesorder")
		expect(m.connection).toBe("sb-rest")
		expect(m.refresh).toBe(false)
		expect(State.loading(s, "std")).toBe(true)
	end)

	it("labels standard fields from the answer; fields the schema does not title keep their column name", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		expect(State.label(s.cur :: State.Inspection, "tranid")).toBeNil()
		s = State.update(s, {
			t = "result",
			req = (metadataOf(effects) :: State.Effect).req,
			labels = STD,
			fetched = 1000,
			cached = true,
		})
		local cur = s.cur :: State.Inspection
		expect(State.label(cur, "tranid")).toBe("Order #")
		expect(State.label(cur, "memo")).toBeNil()
		expect(cur.stdFetched).toBe(1000)
		expect(cur.stdCached).toBe(true)
	end)

	it("prefers the custom field's own label over the schema title", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		local meta = metadataOf(effects) :: State.Effect
		s = answer(s, queries(effects).labels, rows("labels-rest.json"))
		s = State.update(s, { t = "result", req = meta.req, labels = STD, fetched = 1000 })
		expect(State.label(s.cur :: State.Inspection, "custbody_acme_box")).toBe("Shipping box")
	end)

	it("keeps column names when the metadata read fails, and says why", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		s = answer(s, metadataOf(effects) :: State.Effect, nil, Errors.new("permission", "INSUFFICIENT_PERMISSION"))
		local cur = s.cur :: State.Inspection
		expect(cur.errs.std.kind).toBe("permission")
		expect(State.label(cur, "tranid")).toBeNil()
		expect(State.loading(s, "std")).toBe(false)
	end)

	it("does not ask on a RESTlet connection, which cannot reach the REST record service, and says so", function()
		local restletCfg = Config.parse(
			[[{
				"accounts": [{ "id": "sb", "label": "SB1", "account_id": "1234567_SB1" }],
				"connections": [{ "id": "sb-restlet", "account": "sb", "auth": "tba", "transport": "restlet",
					"restlet": { "script": "customscript_acme_suiteql", "deploy": "customdeploy_acme_suiteql" } }]
			}]],
			json.decode
		)
		local s, effects = State.init({ "type=salesorder", "id=123" }, nil, restletCfg, env)
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		expect(metadataOf(effects)).toBeNil()
		expect((s.cur :: State.Inspection).stdNote).toContain("RESTlet")
	end)

	it("does not ask for a generic type the REST service has no record type for", function()
		local s, effects = State.init({ "connection=sb-rest", "type=item", "id=7" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, { { id = "7", itemid = "Acme widget", itemtype = "Mystery" } })
		expect(metadataOf(effects)).toBeNil()
		expect((s.cur :: State.Inspection).stdNote).toContain("column names")
	end)

	it("refreshes the labels from NetSuite on l, bypassing the week-long cache", function()
		local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
		s, effects = answer(s, queries(effects).record, rows("salesorder-rest.json"))
		s = State.update(s, { t = "result", req = (metadataOf(effects) :: State.Effect).req, labels = STD })
		local _, chip = State.update(s, { t = "action", act = "labels" })
		expect((metadataOf(chip) :: State.Effect).refresh).toBe(true)
		s, effects = key(s, "l", "l")
		local m = metadataOf(effects) :: State.Effect
		expect(m.refresh).toBe(true)
		expect(m.record).toBe("salesorder")
		-- the labels shown stay until the new ones arrive
		expect(State.label(s.cur :: State.Inspection, "tranid")).toBe("Order #")
	end)
end)

describe("related records in a new pane", function()
	it("opens the selected related record beside on shift+enter, through a link the block grants", function()
		local s = key(loadedOrder(), "3", "3")
		local after, effects = State.update(s, { t = "key", key = { name = "enter", shift = true } })
		expect(effects).toEqual({
			{ t = "split", url = "tern-netsuite://inspect?connection=sb-rest&type=entity&id=42" },
		})
		-- this pane keeps its record and history
		expect((after.cur :: State.Inspection).ref.id).toBe("123")
		expect(#after.history).toBe(0)
	end)

	it("opens a shift-clicked related row beside too", function()
		local s = key(loadedOrder(), "3", "3")
		local _, effects = State.update(s, { t = "action", act = "go", value = "2", shift = true })
		expect(effects).toEqual({
			{ t = "split", url = "tern-netsuite://inspect?connection=sb-rest&type=subsidiary&id=1" },
		})
	end)
end)

return nil
