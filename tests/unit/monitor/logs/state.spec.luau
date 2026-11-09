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

	it("pages and jumps with the keys Tern sends (page_down, page_up, G as shift+g, home, end)", function()
		local s = loaded()
		local newest = selId(s)
		local list = State.visible(s)
		local oldest = list[#list].id
		s = press(s, "page_down")
		expect(selId(s)).toBe(oldest)
		s = press(s, "page_up")
		expect(selId(s)).toBe(newest)
		s = State.update(s, { t = "key", key = key("g", "G", { shift = true }) })
		expect(selId(s)).toBe(oldest)
		s = press(s, "home")
		expect(selId(s)).toBe(newest)
		s = press(s, "end")
		expect(selId(s)).toBe(oldest)
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

	-- Rows at `logged`, with ids from `first` up.
	local function burst(first: number, n: number, logged: string): { any }
		local out = {}
		for i = 1, n do
			local r = table.clone(rows[1])
			r.internalid = first + i
			r.logged = logged
			table.insert(out, r)
		end
		return out
	end

	-- Runs the pending timer and answers its query with `page`.
	local function poll(
		s: State.State,
		effects: { State.Effect },
		page: { any },
		full: boolean
	): (State.State, { State.Effect }, State.Effect)
		local timer = only(effects, "timer") :: State.Effect
		local s2, tick = State.update(s, { t = "tick", req = timer.req })
		local q = only(tick, "query") :: State.Effect
		local s3, after = State.update(s2, { t = "result", req = q.req, rows = page, truncated = full, at = "x" })
		return s3, after, q
	end

	local function nextParams(s: State.State, effects: { State.Effect }): { any }
		local timer = only(effects, "timer") :: State.Effect
		local _, tick = State.update(s, { t = "tick", req = timer.req })
		return (only(tick, "query") :: State.Effect).params :: { any }
	end

	it("does not stall when a full page holds only rows it has already seen", function()
		local s, effects = loaded()
		-- The overlap window re-reads a full page of known rows: continue from
		-- the page's newest row instead of jumping past unseen ones.
		s, effects = poll(s, effects, { rows[7] }, true)
		expect((only(effects, "timer") :: State.Effect).ms).toBe(0)
		expect(nextParams(s, effects)).toEqual({ "2026-10-08 22:16:09" })
		expect(s.notice).toBeNil()
		-- Still a full page of known rows from that very second: only now skip it.
		s, effects = poll(s, effects, { rows[7] }, true)
		expect(nextParams(s, effects)).toEqual({ "2026-10-08 22:16:10" })
		expect(s.notice).toContain("2026-10-08 22:16:09")
	end)

	it("continues a full page from the page's newest row so late rows before the newest seen one are read", function()
		local s, effects = loaded()
		s, effects = poll(s, effects, burst(6000000, 5, "2026-10-08 22:15:00"), true)
		-- The buffer already holds 22:16:09; rows between 22:15:00 and it may
		-- still be unread past the page cut.
		expect(nextParams(s, effects)).toEqual({ "2026-10-08 22:15:00" })
		expect(s.notice).toBeNil()
	end)

	it("never shows a row twice when a later poll re-reads rows a full page moved past", function()
		local s, effects = loaded()
		s, effects = poll(s, effects, burst(6000000, 3, "2026-10-08 22:16:20"), true)
		-- The burst ended; the next poll starts in the overlap window again and
		-- returns rows from before the burst.
		s, effects = poll(s, effects, { rows[7], rows[1] }, false)
		s = poll(s, effects, { rows[7] }, false)
		local ids: { [number]: boolean } = {}
		for _, e in State.visible(s) do
			expect(ids[e.id]).toBeNil()
			ids[e.id] = true
		end
		expect(#State.visible(s)).toBe(10)
	end)

	it("reads a burst in full after an empty first load instead of only its newest 200 rows", function()
		local s, effects = State.init({ "script=customscript_a" }, nil, cfg, env)
		local q = only(effects, "query") :: State.Effect
		s, effects = State.update(s, { t = "result", req = q.req, rows = {}, truncated = false, at = "x" })
		local timer = only(effects, "timer") :: State.Effect
		local s2, tick = State.update(s, { t = "tick", req = timer.req })
		q = only(tick, "query") :: State.Effect
		expect(q.max_rows).toBe(State.POLL_ROWS)
		expect(q.sql).toContain("ORDER BY n.date, n.internalid)")
		local _, after = State.update(
			s2,
			{ t = "result", req = q.req, rows = burst(6000000, 3, "2026-10-08 22:16:20"), truncated = true, at = "x" }
		)
		expect((only(after, "timer") :: State.Effect).ms).toBe(0)
	end)

	it("never retries a failing connection more often than a healthy one is polled", function()
		for _, kind in { "network", "rate_limit", "server" } do
			for failures = 1, 6 do
				expect(State.backoff(failures, kind, 600000) >= 600000).toBe(true)
			end
		end
	end)

	describe("opened from a link", function()
		local args = { "connection=prod-rest", "script=customscript_a", "since=30m", "hold=1" }

		it("queries nothing until Enter, so a printed link cannot start NetSuite queries", function()
			local s, effects = State.init(args, nil, cfg, env)
			expect(only(effects, "query")).toBeNil()
			expect(State.held(s)).toBe(true)
			for _, k in { "p", "r", "c", "l", "j" } do
				local _, e = press(s, k, k)
				expect(only(e, "query")).toBeNil()
			end
			for _, act in { "pause", "reload", "conn" } do
				local _, e = State.update(s, { t = "action", act = act, value = "sb-rest" })
				expect(only(e, "query")).toBeNil()
			end
			local started, e = press(s, "enter")
			local q = only(e, "query") :: State.Effect
			expect(q.connection).toBe("prod-rest")
			expect(q.params).toEqual({ "customscript_a", 30 } :: { any })
			expect(State.held(started)).toBe(false)
		end)

		it("still closes on escape while waiting", function()
			local s = State.init(args, nil, cfg, env)
			local _, e = press(s, "escape")
			expect(only(e, "exit") ~= nil).toBe(true)
		end)

		it("keeps tailing after a restart once the user started it", function()
			local s = State.init(args, nil, cfg, env)
			s = press(s, "enter")
			local r, effects = State.init(args, State.save(s), cfg, env)
			expect(State.held(r)).toBe(false)
			expect(only(effects, "query") ~= nil).toBe(true)
		end)
	end)

	it("closes on escape", function()
		local _, effects = press(loaded(), "escape")
		expect(only(effects, "exit") ~= nil).toBe(true)
	end)
end)

return nil
