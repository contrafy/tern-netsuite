--!strict
local Config = require("../../../plugin/lib/config")
local Errors = require("../../../plugin/lib/ns/errors")
local State = require("../../../plugin/lib/console/state")
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
		{ "id": "prod-rest", "account": "prod", "auth": "tba", "transport": "rest", "read_only": false }
	],
	"console": { "max_rows": 250 }
}]]

local cfg = Config.parse(CONFIG, json.decode)
local env: State.Env = { null = json.null }

local function data(over: { [string]: any }?): State.Data
	local d: { [string]: any } = { history = {}, saved = {}, lastConnection = nil }
	for k, v in (over or {}) :: { [string]: any } do
		d[k] = v
	end
	return d :: any
end

local function key(name: string, text: string?, mods: { [string]: boolean }?): State.Key
	local k: { [string]: any } = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
	for m, v in (mods or {}) :: { [string]: boolean } do
		k[m] = v
	end
	return k :: any
end

local function only(effects: { State.Effect }, kind: string): State.Effect?
	local found: State.Effect? = nil
	for _, e in effects do
		if e.t == kind then
			expect(found).toBeNil()
			found = e
		end
	end
	return found
end

local function start(args: { string }?, saved: any?, d: State.Data?): State.State
	local s = State.init(args or {}, saved, cfg, env, d or data())
	return s
end

local function send(s: State.State, msg: State.Msg): (State.State, { State.Effect })
	return State.update(s, msg)
end

local function press(s: State.State, ...: State.Key): (State.State, { State.Effect })
	local all: { State.Effect } = {}
	for _, k in { ... } do
		local effects
		s, effects = State.update(s, { t = "key", key = k })
		for _, e in effects do
			table.insert(all, e)
		end
	end
	return s, all
end

local function typeText(s: State.State, text: string): State.State
	s = State.update(s, { t = "key", key = key("paste", text) })
	return s
end

local RUN = key("enter", nil, { ctrl = true })

local function ran(s: State.State, sql: string): (State.State, State.Effect)
	s = typeText(s, sql)
	local effects
	s, effects = press(s, RUN)
	return s, only(effects, "query") :: State.Effect
end

local restRows = json.decode(fixtures.read("ns/rest/page1.json")).items
for _, r in restRows do
	r.links = nil
end

describe("console runs", function()
	it("runs the editor's query with Ctrl+Enter on the selected connection, capped at console.max_rows", function()
		local _, q = ran(start(), "SELECT id, title FROM scriptnote")
		expect(q.connection).toBe("sb-rest")
		expect(q.sql).toBe("SELECT id, title FROM scriptnote")
		expect(q.max_rows).toBe(250)
	end)

	it("refuses anything but one SELECT or WITH, even on a connection that allows writes, and explains it", function()
		local s = State.update(start(), { t = "action", act = "conn", value = "prod-rest" })
		local effects
		s = typeText(s, "SELECT 1 FROM dual; DELETE FROM customer")
		s, effects = press(s, RUN)
		expect(only(effects, "query")).toBeNil()
		local err = s.err :: Errors.NsError
		expect(err.code).toBe(Errors.READ_ONLY)
		expect(err.message).toContain("only a single statement may be sent")
	end)

	it("shows the rows of its latest run only, ignoring a late answer of an earlier one", function()
		local s, first = ran(start(), "SELECT id FROM a")
		local second
		s, second = ran(s, " ")
		s = send(s, { t = "result", req = first.req, rows = { { id = "1" } } })
		expect(s.result).toBeNil()
		s = send(s, { t = "result", req = second.req, rows = restRows, pages = 1, elapsed = 420, at = "10:15:00" })
		local r = s.result :: State.Result
		expect(r.columns).toEqual({ "id", "title" })
		expect(#r.rows).toBe(2)
		expect(r.elapsed).toBe(420)
	end)

	it("keeps NetSuite's error with the connection it came from", function()
		local s, q = ran(start(), "SELECT nope FROM scriptnote")
		s = send(s, { t = "result", req = q.req, err = Errors.new("query", "Unknown identifier 'nope'", nil, 400) })
		expect((s.err :: Errors.NsError).message).toBe("Unknown identifier 'nope'")
		expect(s.errConnection).toBe("sb-rest")
		expect(s.running).toBeNil()
	end)

	it("marks results of a production connection, whichever connection is selected later", function()
		local s = State.update(start(), { t = "action", act = "conn", value = "prod-rest" })
		local q
		s, q = ran(s, "SELECT id FROM customer")
		s = send(s, { t = "result", req = q.req, rows = { { id = "5" } } })
		s = send(s, { t = "action", act = "conn", value = "sb-rest" })
		expect((s.result :: State.Result).production).toBe(true)
		expect(State.title(s)).toBe("SuiteQL · sb-rest")
	end)
end)

describe("console history", function()
	local d = data({
		history = {
			{ sql = "SELECT 1", at = 1 },
			{ sql = "SELECT a,\n  b FROM t", at = 2 },
		},
	})

	it("recalls older queries with Up on the first line and returns to the draft with Down", function()
		local s = typeText(start(nil, nil, d), "SELECT draft")
		s = press(s, key("up"))
		expect(s.editor.text).toBe("SELECT a,\n  b FROM t")
		-- The caret sits on the recalled query's first line: Up goes on.
		s = press(s, key("up"))
		expect(s.editor.text).toBe("SELECT 1")
		s = press(s, key("down"))
		expect(s.editor.text).toBe("SELECT a,\n  b FROM t")
		s = press(s, key("down"))
		expect(s.editor.text).toBe("SELECT draft")
	end)

	it("moves between lines of a multi-line query before recalling history", function()
		local s = typeText(start(nil, nil, d), "SELECT x\nFROM y")
		s = press(s, key("up"))
		expect(s.editor.text).toBe("SELECT x\nFROM y")
		s = press(s, key("up"))
		expect(s.editor.text).toBe("SELECT a,\n  b FROM t")
	end)

	it("records every run for the host to append to the history file", function()
		local s = start(nil, nil, d)
		s = typeText(s, "SELECT 2")
		local _, effects = press(s, RUN)
		local h = only(effects, "history") :: State.Effect
		expect(h.sql).toBe("SELECT 2")
		expect(h.connection).toBe("sb-rest")
	end)
end)

describe("console launch", function()
	it("loads a .sql file and runs it when the palette asks", function()
		local _, effects = State.init({ "file=/tmp/acme/sql/open.sql", "run=1" }, nil, cfg, env, data())
		local r = only(effects, "read") :: State.Effect
		expect(r.path).toBe("/tmp/acme/sql/open.sql")
		expect(r.run).toBe(true)
	end)

	it("never runs on its own against production: it waits for Ctrl+Enter", function()
		local s, effects =
			State.init({ "connection=prod-rest", "file=/tmp/acme/a.sql", "run=1" }, nil, cfg, env, data())
		expect((only(effects, "read") :: State.Effect).run).toBe(false)
		expect((s.notice :: State.Notice).text).toContain("production connection")
	end)

	it("starts on the connection the last console used", function()
		local s = start(nil, nil, data({ lastConnection = "prod-rest" }))
		expect((State.target(s) :: State.Target).id).toBe("prod-rest")
	end)

	it("restores the editor after a restart without running anything again", function()
		local s, effects =
			State.init({ "file=/tmp/a.sql", "run=1" }, State.save(typeText(start(), "SELECT 9")), cfg, env, data())
		expect(s.editor.text).toBe("SELECT 9")
		expect(only(effects, "read")).toBeNil()
		expect(only(effects, "query")).toBeNil()
	end)

	it("runs a loaded file once its text arrives", function()
		local s = start({ "file=/tmp/a.sql", "run=1" })
		local effects
		s, effects = send(s, { t = "loaded", path = "/tmp/a.sql", text = "SELECT 3", run = true })
		expect(s.editor.text).toBe("SELECT 3")
		expect((only(effects, "query") :: State.Effect).sql).toBe("SELECT 3")
	end)
end)

describe("console results grid", function()
	local rows = {
		{ id = "3", companyname = "Globex" },
		{ id = "1", companyname = "Acme" },
		{ id = "2", companyname = "Initech" },
	}

	local function withRows(): State.State
		local s, q = ran(start(), "SELECT id, companyname FROM customer")
		s = send(s, { t = "result", req = q.req, rows = rows })
		s = press(s, key("tab"))
		expect(s.focus).toBe("grid")
		return s
	end

	local function shown(s: State.State): { string }
		local out = {}
		for _, i in (s.view :: State.View).order do
			table.insert(out, rows[i].id)
		end
		return out
	end

	it("sorts by the current column, then reverses, then restores NetSuite's order", function()
		local s = withRows()
		s = press(s, key("s", "s"))
		expect(shown(s)).toEqual({ "1", "2", "3" })
		s = press(s, key("s", "s"))
		expect(shown(s)).toEqual({ "3", "2", "1" })
		s = press(s, key("s", "s"))
		expect(shown(s)).toEqual({ "3", "1", "2" })
	end)

	it("keeps the selected row selected through a sort", function()
		local s = withRows()
		s = press(s, key("j", "j"))
		expect((State.selectedRow(s))).toBe(rows[2])
		s = State.update(s, { t = "action", act = "sort", value = "2" })
		expect((State.selectedRow(s))).toBe(rows[2])
	end)

	it("filters rows as the filter is typed", function()
		local s = withRows()
		s = press(s, key("/", "/"), key("i", "i"), key("n", "n"))
		expect(s.focus).toBe("filter")
		expect(shown(s)).toEqual({ "2" })
		s = press(s, key("enter"))
		expect(s.focus).toBe("grid")
	end)

	it("exports what the grid shows: copy as CSV or TSV, save as CSV or JSON, open as a table", function()
		local s = withRows()
		s = press(s, key("s", "s"))
		local _, effects = press(s, key("y", "y"))
		local e = only(effects, "export") :: State.Effect
		expect(e.how).toBe("copy")
		expect(e.text).toBe("id,companyname\n1,Acme\n2,Initech\n3,Globex\n")
		_, effects = press(s, key("Y", "Y", { shift = true }))
		expect((only(effects, "export") :: State.Effect).format).toBe("tsv")
		_, effects = press(s, key("W", "W", { shift = true }))
		e = only(effects, "export") :: State.Effect
		expect(e.how).toBe("file")
		expect(e.format).toBe("json")
		_, effects = press(s, key("o", "o"))
		expect((only(effects, "export") :: State.Effect).how).toBe("view")
	end)

	it("inspects the selected row's record with the table of a single-table query as its type", function()
		local s = press(withRows(), key("j", "j"))
		local _, effects = press(s, key("i", "i"))
		local e = only(effects, "inspect") :: State.Effect
		expect(e.connection).toBe("sb-rest")
		expect(e.type).toBe("customer")
		expect(e.id).toBe("1")
	end)

	it("opens a row's inspector with Enter or a click, and closes it with Esc", function()
		local s = press(withRows(), key("enter"))
		expect((s.view :: State.View).inspect).toBe(true)
		s = press(s, key("escape"))
		expect((s.view :: State.View).inspect).toBe(false)
		s = State.update(s, { t = "action", act = "row", value = "3" })
		expect((s.view :: State.View).inspect).toBe(true)
		expect((State.selectedRow(s))).toBe(rows[3])
	end)
end)

describe("console saved queries", function()
	it("lists saved queries and folder files, loads the chosen one, and Ctrl+Enter also runs it", function()
		local s, effects = press(start(), key("o", "o", { ctrl = true }))
		expect(s.focus).toBe("picker")
		expect(only(effects, "list") ~= nil).toBe(true)
		s = send(s, {
			t = "listed",
			saved = { { name = "Open orders", sql = "SELECT id FROM transaction", at = 5 } },
			files = { { path = "/tmp/acme/sql/c.sql", name = "c.sql", title = "Customers", folder = "sql" } },
			problems = {},
		})
		local loaded
		loaded, effects = press(s, key("enter", nil, { ctrl = true }))
		expect(loaded.editor.text).toBe("SELECT id FROM transaction")
		expect(only(effects, "query") ~= nil).toBe(true)
		loaded, effects = press(s, key("down"), key("enter"))
		expect(only(effects, "read")).toEqual({ t = "read", path = "/tmp/acme/sql/c.sql", run = false })
		expect(loaded.focus).toBe("editor")
	end)

	it("deletes only queries saved in plugin data; folder files are read-only", function()
		local s = press(start(), key("o", "o", { ctrl = true }))
		s = send(s, {
			t = "listed",
			saved = { { name = "Mine", sql = "SELECT 1", at = 1 } },
			files = { { path = "/tmp/acme/sql/c.sql", name = "c.sql", folder = "sql" } },
		})
		local _, effects = press(s, key("d", "d", { ctrl = true }))
		expect(only(effects, "delete")).toEqual({ t = "delete", name = "Mine" })
		local after
		after, effects = press(s, key("down"), key("d", "d", { ctrl = true }))
		expect(only(effects, "delete")).toBeNil()
		expect((after.notice :: State.Notice).text).toContain("read-only")
	end)

	it("saves the editor's query under a name, suggesting its leading comment", function()
		local s = typeText(start(), "-- Open orders\nSELECT id FROM transaction")
		s = press(s, key("s", "s", { ctrl = true }))
		expect(s.focus).toBe("name")
		expect((s.name :: any).text).toBe("Open orders")
		local _, effects = press(s, key("paste", " (SB1)"), key("enter"))
		expect(only(effects, "store")).toEqual({
			t = "store",
			name = "Open orders (SB1)",
			sql = "-- Open orders\nSELECT id FROM transaction",
		})
	end)
end)

return nil
