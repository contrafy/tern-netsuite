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

-- A sales order read in full from the fixtures.
local function loadedOrder(): State.State
	local s, effects = State.init({ "connection=sb-rest", "type=salesorder", "id=123" }, nil, cfg, env)
	local q = queries(effects)
	s, effects = answer(s, q.record, rows("salesorder-rest.json"))
	q = queries(effects)
	local after: { State.Effect }
	s, after = answer(s, q.labels, rows("labels-rest.json"))
	s = answer(s, queries(after).display, rows("display-rest.json"))
	s = answer(s, q.notes, rows("notes-restlet.json"))
	s = answer(s, q.lines, rows("lines-rest.json"))
	s = answer(s, q.children, rows("children-rest.json"))
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
		expect(partsOf(next)).toEqual({ "children", "labels", "lines", "notes" })
		expect(queries(next).notes.params).toEqual({ 123, -30 })
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

return nil
