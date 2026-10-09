--!strict
local Config = require("../../../../plugin/lib/config")
local Query = require("../../../../plugin/lib/monitor/logs/query")
local State = require("../../../../plugin/lib/monitor/logs/state")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CONFIG = [[{
	"accounts": [
		{ "id": "sb", "label": "SB1", "account_id": "1234567_SB1" },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "production": true }
	],
	"connections": [
		{ "id": "sb-rest", "account": "sb", "auth": "tba", "transport": "rest" },
		{ "id": "prod-rest", "account": "prod", "auth": "tba", "transport": "rest" }
	],
	"monitor": { "log_poll_seconds": 15, "log_title_json": true }
}]]

local cfg = Config.parse(CONFIG, json.decode)
local env: State.Env = { decode = json.decode, null = json.null }
local rows = json.decode(fixtures.read("monitor/logs/restlet-rows.json"))

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

local function press(s: State.State, name: string, text: string?): (State.State, { State.Effect })
	return State.update(s, { t = "key", key = key(name, text) })
end

local function typeText(s: State.State, text: string): State.State
	for i = 1, #text do
		local c = string.sub(text, i, i)
		s = press(s, c, c)
	end
	return s
end

-- A started block whose first load returned the fixture rows.
local function loaded(args: { string }?): (State.State, { State.Effect })
	local s, effects = State.init(args or {}, nil, cfg, env)
	local q = only(effects, "query") :: State.Effect
	return State.update(s, { t = "result", req = q.req, rows = rows, truncated = false, at = "22:16:10" })
end

local function err(kind: string, code: string?): any
	return { kind = kind, message = "it failed", code = code }
end

local function selId(s: State.State): number?
	local e = State.selected(s)
	return if e then e.id else nil
end

describe("the execution log block", function()
	it("starts by loading the newest rows of the first configured connection", function()
		local s, effects = State.init({}, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		expect(q.connection).toBe("sb-rest")
		expect(q.sql).toBe(Query.first({ scripts = {} }, State.FIRST_ROWS).sql)
		expect(q.max_rows).toBe(State.FIRST_ROWS)
		expect((State.target(s) :: State.Target).production).toBe(false)
	end)

	it("says what to do and queries nothing when no connection is configured", function()
		local empty = Config.parse("{}", json.decode)
		local s, effects = State.init({}, nil, empty, env)
		expect(#effects).toBe(0)
		expect(State.target(s)).toBeNil()
	end)

	it("polls every log_poll_seconds after a load, from the watermark minus the overlap", function()
		local s, effects = loaded()
		expect(#State.visible(s)).toBe(7)
		local timer = only(effects, "timer") :: State.Effect
		expect(timer.ms).toBe(15000)
		local _, tick = State.update(s, { t = "tick", req = timer.req })
		local q = only(tick, "query") :: State.Effect
		expect(q.sql).toBe(Query.poll({ scripts = {} }, "x", State.POLL_ROWS).sql)
		expect(q.params).toEqual({ Query.shift("2026-10-08 22:16:09", -Query.OVERLAP_SECONDS) })
	end)

	it("ignores a timer or a result from before a reload or a connection switch", function()
		local s, effects = loaded()
		local timer = only(effects, "timer") :: State.Effect
		local switched, sw = press(s, "c", "c")
		local q = only(sw, "query") :: State.Effect
		expect(q.connection).toBe("prod-rest")
		expect(#State.visible(switched)).toBe(0)
		local same, none = State.update(switched, { t = "tick", req = timer.req })
		expect(#none).toBe(0)
		expect(same).toBe(switched)
		local stale = State.update(switched, { t = "result", req = timer.req, rows = rows, at = "x" })
		expect(#State.visible(stale)).toBe(0)
	end)

	it("adds only new rows on a poll and keeps its place", function()
		local s, effects = loaded()
		local timer = only(effects, "timer") :: State.Effect
		local s2, tick = State.update(s, { t = "tick", req = timer.req })
		local q = only(tick, "query") :: State.Effect
		local newRow = table.clone(rows[1])
		newRow.internalid = 5771532
		newRow.logged = "2026-10-08 22:16:20"
		local s3 = State.update(s2, { t = "result", req = q.req, rows = { rows[2], newRow }, at = "22:16:21" })
		local v = State.visible(s3)
		expect(#v).toBe(8)
		expect(v[1].id).toBe(5771532)
	end)

	it("backs off exponentially on rate limits and resets after a success", function()
		local s, effects = State.init({}, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		local delays = {}
		for _ = 1, 8 do
			local timer
			s, effects =
				State.update(s, { t = "result", req = q.req, err = err("rate_limit", "SSS_REQUEST_LIMIT_EXCEEDED") })
			timer = only(effects, "timer") :: State.Effect
			table.insert(delays, timer.ms)
			s, effects = State.update(s, { t = "tick", req = timer.req })
			q = only(effects, "query") :: State.Effect
		end
		expect(delays[1]).toBe(30000)
		expect(delays[2]).toBe(60000)
		expect(delays[3]).toBe(120000)
		expect(delays[8]).toBe(State.MAX_BACKOFF_MS)
		expect((State.error(s) :: any).kind).toBe("rate_limit")
		s, effects = State.update(s, { t = "result", req = q.req, rows = rows, at = "x" })
		expect((only(effects, "timer") :: State.Effect).ms).toBe(15000)
		expect(State.error(s)).toBeNil()
	end)

	it("keeps retrying network failures such as no open window, showing the error meanwhile", function()
		local s, effects = State.init({}, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		s, effects = State.update(s, { t = "result", req = q.req, err = err("network", "TNS_NO_WINDOW") })
		expect((only(effects, "timer") :: State.Effect).ms).toBe(15000)
		expect((State.error(s) :: any).code).toBe("TNS_NO_WINDOW")
	end)

	it("stops polling on missing credentials and offers the connect block", function()
		local s, effects = State.init({}, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		s, effects = State.update(s, { t = "result", req = q.req, err = err("auth", "TNS_NO_CREDENTIALS") })
		expect(only(effects, "timer")).toBeNil()
		expect((State.error(s) :: any).code).toBe("TNS_NO_CREDENTIALS")
		local _, act = State.update(s, { t = "action", act = "connect" })
		expect((only(act, "open") :: State.Effect).url).toBe("tern-netsuite://logs/connect?connection=sb-rest")
	end)

	it("retries a stopped tail on r and clears the error once rows arrive", function()
		local s, effects = State.init({}, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		s = State.update(s, { t = "result", req = q.req, err = err("permission") })
		s, effects = press(s, "r", "r")
		q = only(effects, "query") :: State.Effect
		s = State.update(s, { t = "result", req = q.req, rows = rows, at = "x" })
		expect(State.error(s)).toBeNil()
		expect(#State.visible(s)).toBe(7)
	end)

	it("pauses without dropping rows and catches up immediately on resume", function()
		local s, effects = loaded()
		local timer = only(effects, "timer") :: State.Effect
		s = press(s, "p", "p")
		expect(State.paused(s)).toBe(true)
		local _, tick = State.update(s, { t = "tick", req = timer.req })
		expect(#tick).toBe(0)
		s, effects = press(s, "p", "p")
		expect(only(effects, "query") ~= nil).toBe(true)
	end)

	it("filters by level with l, cycling back to everything", function()
		local s = loaded()
		local counts = {}
		for _ = 1, 4 do
			s = press(s, "l", "l")
			table.insert(counts, #State.visible(s))
		end
		expect(counts).toEqual({ 6, 3, 0, 7 })
	end)

	it("edits the text filter after / and closes the editor, not the block, on escape", function()
		local s, effects = press(loaded(), "/", "/")
		expect((only(effects, "focus") :: State.Effect).id).toBe(State.FILTER_INPUT)
		s = typeText(s, "ns:suiteql")
		expect(#State.visible(s)).toBe(3)
		s = press(s, "backspace")
		expect(State.filterText(s)).toBe("ns:suiteq")
		s, effects = press(s, "escape")
		expect(only(effects, "exit")).toBeNil()
		local _, closing = press(s, "escape")
		expect(only(closing, "exit") ~= nil).toBe(true)
	end)

	it("moves the selection with j/k and opens the parsed detail with enter", function()
		local s = loaded()
		expect(selId(s)).toBe(5771131)
		s = press(s, "j", "j")
		s = press(s, "down")
		expect(selId(s)).toBe(5771130)
		s = press(s, "k", "k")
		expect(selId(s)).toBe(5771027)
		s = press(s, "up")
		s = press(s, "up")
		expect(selId(s)).toBe(5771131)
		s = press(s, "j", "j")
		s = press(s, "j", "j")
		s = press(s, "j", "j")
		expect(selId(s)).toBe(5771329)
		s = press(s, "enter")
		local d = State.detail(s) :: any
		expect(d.json).toBe(true)
		s = press(s, "enter")
		expect(State.detail(s)).toBeNil()
	end)

	it("keeps the selected row selected while new rows arrive above it", function()
		local s, effects = loaded()
		local timer = only(effects, "timer") :: State.Effect
		s = press(s, "j", "j")
		local id = selId(s)
		s, effects = State.update(s, { t = "tick", req = timer.req })
		local q = only(effects, "query") :: State.Effect
		local newRow = table.clone(rows[1])
		newRow.internalid = 5771999
		newRow.logged = "2026-10-08 22:17:00"
		s = State.update(s, { t = "result", req = q.req, rows = { newRow }, at = "x" })
		expect(selId(s)).toBe(id)
	end)

	it("scopes queries to the scripts and start time it was launched with", function()
		local s, effects = State.init({ "connection=prod-rest", "script=customscript_a", "since=30m" }, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		expect(q.connection).toBe("prod-rest")
		expect((State.target(s) :: State.Target).production).toBe(true)
		expect(q.params).toEqual({ "customscript_a", 30 } :: { any })
	end)

	it("reports a launch connection that is not configured instead of querying another account", function()
		local s, effects = State.init({ "connection=nope" }, nil, cfg, env)
		expect(only(effects, "query")).toBeNil()
		expect((State.error(s) :: any).code).toBe("TNS_NO_CONNECTION")
	end)

	it("restores its connection, filter and level after a restart", function()
		local s = press(loaded(), "c", "c")
		s = press(s, "l", "l")
		s = press(s, "/", "/")
		s = typeText(s, "exec")
		local r, effects = State.init({}, State.save(s), cfg, env)
		expect((only(effects, "query") :: State.Effect).connection).toBe("prod-rest")
		expect(State.filterText(r)).toBe("exec")
		expect(State.level(r)).toBe(State.level(s))
	end)

	it("does not stall when a full page holds only rows it has already seen", function()
		local s, effects = loaded()
		local timer = only(effects, "timer") :: State.Effect
		s, effects = State.update(s, { t = "tick", req = timer.req })
		local q = only(effects, "query") :: State.Effect
		s, effects = State.update(s, { t = "result", req = q.req, rows = { rows[7] }, truncated = true, at = "x" })
		timer = only(effects, "timer") :: State.Effect
		expect(timer.ms).toBe(0)
		local _, polled = State.update(s, { t = "tick", req = timer.req })
		q = only(polled, "query") :: State.Effect
		expect(q.params).toEqual({ "2026-10-08 22:16:10" })
	end)

	it("closes on escape", function()
		local _, effects = press(loaded(), "escape")
		expect(only(effects, "exit") ~= nil).toBe(true)
	end)
end)

return nil
