--!strict
-- State of the `logs` block: tails a connection's execution log
-- (`scriptnote`). `update` returns the next state and the effects the host
-- runs (query through NsHost, arm a timer, focus the filter, open a link,
-- save, exit). Nothing here touches `tern`.
--
-- One chain per state: a query's result arms one timer, the timer starts one
-- query. Every query and timer carries a token (`req`); a reload, a
-- connection switch or a pause replaces the expected token, so late results
-- and ticks of an older chain change nothing.

local Buffer = require("./buffer")
local Config = require("../../config")
local Connect = require("../../ns/connect")
local Detail = require("./detail")
local Entry = require("./entry")
local Errors = require("../../ns/errors")
local Filter = require("./filter")
local Link = require("./link")
local Query = require("./query")

type Entry = Entry.Entry
type NsError = Errors.NsError

local M = {}

export type Target = Connect.Target

export type Key = {
	name: string,
	text: string?,
	ctrl: boolean?,
	alt: boolean?,
	shift: boolean?,
	meta: boolean?,
}

export type Env = {
	decode: (string) -> any,
	null: any,
}

export type Effect = {
	t: "query" | "timer" | "focus" | "open" | "save" | "exit",
	req: number?,
	connection: string?,
	sql: string?,
	params: { any }?,
	max_rows: number?,
	ms: number?,
	id: string?,
	url: string?,
}

export type Msg = {
	t: "key" | "action" | "result" | "tick" | "resize",
	key: Key?,
	act: string?,
	value: string?,
	req: number?,
	rows: { any }?,
	truncated: boolean?,
	err: NsError?,
	-- Wall-clock time of the result, as the host formats it.
	at: string?,
	-- resize: the block's height in lines and width in cells.
	height: number?,
	width: number?,
}

type Pending = { kind: "first" | "poll", max: number, ascending: boolean }

export type State = {
	targets: { Target },
	-- Index into `targets`; 0 when none is chosen.
	selected: number,
	scope: Query.Scope,
	pollMs: number,
	titleJson: boolean,
	env: Env,
	buffer: Buffer.Buffer,
	filterText: string,
	filter: Filter.Filter,
	editing: boolean,
	-- Minimum level rank (Entry.rank).
	level: number,
	paused: boolean,
	seq: number,
	inflight: number?,
	pending: Pending?,
	timer: number?,
	-- Set once rows arrived: later queries poll from `from`.
	loaded: boolean,
	from: string?,
	failures: number,
	err: NsError?,
	-- A non-retryable error stopped the chain; r restarts it.
	stopped: boolean,
	retryMs: number?,
	notice: string?,
	polledAt: string?,
	-- nil follows the newest row.
	selId: number?,
	detailOpen: boolean,
	parsed: { id: number, p: Detail.Parsed }?,
	offset: number,
	height: number?,
	width: number?,
}

M.FIRST_ROWS = 200
M.POLL_ROWS = 1000
M.CAP = Buffer.DEFAULT_CAP
M.MAX_BACKOFF_MS = 300000
M.FILTER_INPUT = "main.filter"
M.SAVE_VERSION = 1
-- Lines of the block that are not log rows (header, filter, status, hints)
-- and an estimate of the detail dock.
M.CHROME_LINES = 9
M.DOCK_LINES = 8
-- Tern 0.6.3 reports 80x24 for a block that never resized, whatever its
-- real size, so the window never shrinks below this many rows.
M.MIN_VIEWPORT = 12
M.SCROLLOFF = 2

-- Accessors ---------------------------------------------------------------------

function M.target(s: State): Target?
	return s.targets[s.selected]
end

-- Rows that pass the filter and level, newest first.
function M.visible(s: State): { Entry }
	local out: { Entry } = {}
	local entries = s.buffer.entries
	local all = Filter.isEmpty(s.filter) and s.level <= 1
	for i = #entries, 1, -1 do
		local e = entries[i]
		if all or Filter.matches(e, s.filter, s.level) then
			table.insert(out, e)
		end
	end
	return out
end

local function indexOf(list: { Entry }, id: number?): number
	if id == nil then
		return 1
	end
	for i, e in list do
		if e.id == id then
			return i
		end
	end
	return 1
end

function M.selectedIndex(s: State, list: { Entry }?): number
	return indexOf(list or M.visible(s), s.selId)
end

function M.selected(s: State): Entry?
	local list = M.visible(s)
	return list[indexOf(list, s.selId)]
end

-- The parsed detail of the selected row while the detail is open.
function M.detail(s: State): Detail.Parsed?
	if not s.detailOpen or s.parsed == nil then
		return nil
	end
	return s.parsed.p
end

function M.error(s: State): NsError?
	return s.err
end

function M.paused(s: State): boolean
	return s.paused
end

function M.filterText(s: State): string
	return s.filterText
end

function M.level(s: State): number
	return s.level
end

function M.viewport(height: number?, detailOpen: boolean): number
	local h = (height or 40) - M.CHROME_LINES - (if detailOpen then M.DOCK_LINES else 0)
	return math.max(h, M.MIN_VIEWPORT)
end

-- Rows `[first, last]` of a `size`-row window over `total` rows keeping
-- `selected` SCROLLOFF rows from either edge, moving `offset` minimally.
function M.window(selected: number, total: number, offset: number, size: number): (number, number)
	if total <= size then
		return 1, total
	end
	local so = math.min(M.SCROLLOFF, (size - 1) // 2)
	local sel = math.clamp(selected, 1, total)
	local first = offset
	if sel < first + so then
		first = sel - so
	elseif sel > first + size - 1 - so then
		first = sel - size + 1 + so
	end
	first = math.clamp(first, 1, total - size + 1)
	return first, first + size - 1
end

-- Exponential backoff for retryable errors, starting at the poll interval
-- (twice it for rate limits).
function M.backoff(failures: number, kind: string, pollMs: number): number
	local base = if kind == "rate_limit" then pollMs * 2 else pollMs
	return math.min(base * 2 ^ math.max(failures - 1, 0), M.MAX_BACKOFF_MS)
end

-- Chain -------------------------------------------------------------------------

local function startQuery(s: State, effects: { Effect })
	local tg = M.target(s)
	s.timer = nil
	if tg == nil then
		return
	end
	s.seq += 1
	s.inflight = s.seq
	local clause: Query.Clause
	if s.loaded and s.from then
		clause = Query.poll(s.scope, s.from, M.POLL_ROWS)
		s.pending = { kind = "poll", max = M.POLL_ROWS, ascending = true }
	else
		clause = Query.first(s.scope, M.FIRST_ROWS)
		s.pending = { kind = "first", max = M.FIRST_ROWS, ascending = s.scope.since ~= nil }
	end
	table.insert(effects, {
		t = "query",
		req = s.seq,
		connection = tg.id,
		sql = clause.sql,
		params = clause.params,
		max_rows = (s.pending :: Pending).max,
	})
end

local function schedule(s: State, effects: { Effect }, ms: number)
	if s.paused then
		s.timer = nil
		return
	end
	s.seq += 1
	s.timer = s.seq
	table.insert(effects, { t = "timer", req = s.seq, ms = ms })
end

-- Drops the rows and starts over with a first load.
local function reset(s: State, effects: { Effect })
	s.buffer = Buffer.new(M.CAP)
	s.loaded = false
	s.from = nil
	s.failures = 0
	s.err = nil
	s.stopped = false
	s.retryMs = nil
	s.polledAt = nil
	s.selId = nil
	s.parsed = nil
	s.offset = 1
	s.inflight = nil
	s.pending = nil
	startQuery(s, effects)
end

local function onResult(s: State, msg: Msg, effects: { Effect }): boolean
	if msg.req == nil or msg.req ~= s.inflight then
		return false
	end
	local pending = s.pending or { kind = "first", max = M.FIRST_ROWS, ascending = false }
	s.inflight = nil
	s.pending = nil
	local err = msg.err
	if err then
		s.failures += 1
		s.err = err
		if Errors.retryable(err) then
			s.retryMs = M.backoff(s.failures, err.kind, s.pollMs)
			schedule(s, effects, s.retryMs :: number)
		else
			s.stopped = true
			s.retryMs = nil
		end
		return true
	end
	local rows: { any } = msg.rows or {}
	local list: { Entry } = {}
	for _, r in rows do
		local e = Entry.fromRow(r)
		if e then
			table.insert(list, e)
		end
	end
	local buffer, added = Buffer.merge(s.buffer, list)
	s.failures = 0
	s.err = nil
	s.retryMs = nil
	s.polledAt = msg.at
	local wm = buffer.watermark
	if wm == nil then
		s.buffer = buffer
		schedule(s, effects, s.pollMs)
		return true
	end
	s.loaded = true
	local more = pending.ascending and (msg.truncated == true or #rows >= pending.max)
	local from: string
	if more and added == 0 then
		-- A full page of rows logged in the same second, all seen already.
		from = Query.shift(wm, 1) or wm
		s.notice = string.format("More than %d rows were logged at %s; some were skipped.", pending.max, wm)
	else
		from = if more then wm else Query.nextFrom(wm, false)
	end
	s.from = from
	s.buffer = Buffer.prune(buffer, from)
	schedule(s, effects, if more then 0 else s.pollMs)
	return true
end

local function onTick(s: State, msg: Msg, effects: { Effect }): boolean
	if msg.req == nil or msg.req ~= s.timer then
		return false
	end
	s.timer = nil
	if not s.paused and s.inflight == nil then
		startQuery(s, effects)
	end
	return true
end

-- Commands ----------------------------------------------------------------------

local function move(s: State, delta: number)
	local list = M.visible(s)
	if #list == 0 then
		return
	end
	local i = math.clamp(indexOf(list, s.selId) + delta, 1, #list)
	s.selId = if i == 1 then nil else list[i].id
end

local function selectTarget(s: State, index: number, effects: { Effect }): boolean
	if s.targets[index] == nil or (index == s.selected and s.err == nil) then
		return false
	end
	s.selected = index
	s.notice = nil
	reset(s, effects)
	table.insert(effects, { t = "save" })
	return true
end

local function cycleLevel(s: State)
	s.level = s.level % #Entry.LEVELS + 1
end

local function togglePause(s: State, effects: { Effect })
	s.paused = not s.paused
	if s.paused then
		s.timer = nil
	elseif s.inflight == nil and not s.stopped then
		startQuery(s, effects)
	end
end

local function reload(s: State, effects: { Effect })
	if M.target(s) == nil and #s.targets > 0 then
		s.selected = 1
	end
	s.notice = nil
	reset(s, effects)
end

local function setFilter(s: State, text: string)
	s.filterText = text
	s.filter = Filter.parse(text)
	s.selId = nil
end

local function startEdit(s: State, effects: { Effect })
	s.editing = true
	table.insert(effects, { t = "focus", id = M.FILTER_INPUT })
end

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function editKey(s: State, key: Key): boolean
	local name = key.name
	if name == "escape" or name == "enter" or name == "return" then
		s.editing = false
	elseif name == "backspace" then
		local t = s.filterText
		if t == "" then
			return false
		end
		setFilter(s, string.sub(t, 1, (utf8.offset(t, -1) or #t) - 1))
	elseif name == "u" and key.ctrl then
		setFilter(s, "")
	elseif name == "down" then
		move(s, 1)
	elseif name == "up" then
		move(s, -1)
	elseif name == "paste" and type(key.text) == "string" then
		setFilter(s, s.filterText .. (string.gsub(key.text, "%c", " ")))
	else
		local ch = printable(key)
		if ch == nil then
			return false
		end
		setFilter(s, s.filterText .. ch)
	end
	return true
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	if s.editing then
		return editKey(s, key)
	end
	local name = key.name
	local ch = printable(key)
	local page = M.viewport(s.height, s.detailOpen)
	if name == "escape" then
		table.insert(effects, { t = "exit" })
		return false
	elseif ch == "j" or name == "down" then
		move(s, 1)
	elseif ch == "k" or name == "up" then
		move(s, -1)
	elseif name == "pagedown" then
		move(s, page)
	elseif name == "pageup" then
		move(s, -page)
	elseif ch == "g" or name == "home" then
		s.selId = nil
	elseif ch == "G" or name == "end" then
		move(s, math.huge)
	elseif name == "enter" or name == "return" then
		s.detailOpen = not s.detailOpen
	elseif ch == "/" then
		startEdit(s, effects)
	elseif ch == "l" then
		cycleLevel(s)
	elseif ch == "p" then
		togglePause(s, effects)
	elseif ch == "c" then
		if #s.targets == 0 then
			return false
		end
		return selectTarget(s, s.selected % #s.targets + 1, effects)
	elseif ch == "r" then
		reload(s, effects)
	else
		return false
	end
	return true
end

local function onAction(s: State, act: string, value: string, effects: { Effect }): boolean
	if act == "sel" then
		local id = tonumber(value)
		if id == nil then
			return false
		end
		if s.selId == id or (s.selId == nil and M.visible(s)[1] and M.visible(s)[1].id == id) then
			s.detailOpen = not s.detailOpen
		else
			s.selId = id
			s.detailOpen = true
		end
	elseif act == "detail" then
		s.detailOpen = not s.detailOpen
	elseif act == "level" then
		cycleLevel(s)
		table.insert(effects, { t = "save" })
	elseif act == "pause" then
		togglePause(s, effects)
	elseif act == "reload" then
		reload(s, effects)
	elseif act == "conn" then
		for i, tg in s.targets do
			if tg.id == value then
				return selectTarget(s, i, effects)
			end
		end
		return false
	elseif act == "connect" then
		local tg = M.target(s)
		if tg == nil then
			return false
		end
		table.insert(effects, { t = "open", url = Link.connectUrl(tg.id) })
		return false
	elseif act == "filter-focus" then
		if s.editing then
			return false
		end
		startEdit(s, effects)
	elseif act == "filter-clear" then
		setFilter(s, "")
		s.editing = false
		table.insert(effects, { t = "save" })
	elseif act == "page" then
		move(s, (if value == "up" then -1 else 1) * M.viewport(s.height, s.detailOpen))
	elseif act == "close" then
		table.insert(effects, { t = "exit" })
		return false
	else
		return false
	end
	return true
end

-- Keeps the selection inside the window and the open detail parsed.
local function settle(s: State)
	local list = M.visible(s)
	local i = indexOf(list, s.selId)
	if s.selId ~= nil and (list[i] == nil or list[i].id ~= s.selId) then
		s.selId = nil
		i = 1
	end
	s.offset = M.window(i, #list, s.offset, M.viewport(s.height, s.detailOpen))
	local e = list[i]
	if s.detailOpen and e and (s.parsed == nil or (s.parsed :: any).id ~= e.id) then
		s.parsed = {
			id = e.id,
			p = if s.titleJson
				then Detail.parse(e.detail, s.env.decode, s.env.null)
				else { json = false, tree = nil, nodes = 0, truncated = false },
		}
	elseif e == nil then
		s.parsed = nil
	end
end

-- Init / update -----------------------------------------------------------------

function M.init(args: { string }, saved: any, cfg: Config.Config, env: Env): (State, { Effect })
	local launch, problems = Link.fromArgs(args)
	local targets = Connect.targets(cfg)
	local s: State = {
		targets = targets,
		selected = if #targets > 0 then 1 else 0,
		scope = { scripts = launch.scripts, since = launch.since },
		pollMs = cfg.monitor.log_poll_seconds * 1000,
		titleJson = cfg.monitor.log_title_json,
		env = env,
		buffer = Buffer.new(M.CAP),
		filterText = "",
		filter = Filter.parse(""),
		editing = false,
		level = 1,
		paused = false,
		seq = 0,
		inflight = nil,
		pending = nil,
		timer = nil,
		loaded = false,
		from = nil,
		failures = 0,
		err = nil,
		stopped = false,
		retryMs = nil,
		notice = if #problems > 0 then "Ignored launch arguments: " .. table.concat(problems, "; ") else nil,
		polledAt = nil,
		selId = nil,
		detailOpen = false,
		parsed = nil,
		offset = 1,
		height = nil,
		width = nil,
	}
	local wanted: string? = launch.connection
	if type(saved) == "table" and saved.v == M.SAVE_VERSION then
		if type(saved.filter) == "string" then
			setFilter(s, saved.filter)
		end
		if type(saved.level) == "number" and Entry.LEVELS[saved.level] then
			s.level = saved.level
		end
		if wanted == nil and type(saved.connection) == "string" then
			for i, tg in targets do
				if tg.id == saved.connection then
					s.selected = i
				end
			end
		end
	end
	local effects: { Effect } = {}
	if wanted then
		s.selected = 0
		for i, tg in targets do
			if tg.id == wanted then
				s.selected = i
			end
		end
		if s.selected == 0 then
			s.err = Errors.new(
				"query",
				string.format("no connection %q in the config (connections[])", wanted),
				Errors.NO_CONNECTION
			)
			s.stopped = true
			return s, effects
		end
	end
	startQuery(s, effects)
	return s, effects
end

-- Returns the same state table when the message changed nothing.
function M.update(state: State, msg: Msg): (State, { Effect })
	local s = table.clone(state)
	local effects: { Effect } = {}
	local changed = false
	if msg.t == "key" and msg.key then
		changed = onKey(s, msg.key, effects)
	elseif msg.t == "action" and msg.act then
		changed = onAction(s, msg.act, msg.value or "", effects)
	elseif msg.t == "result" then
		changed = onResult(s, msg, effects)
	elseif msg.t == "tick" then
		changed = onTick(s, msg, effects)
	elseif msg.t == "resize" and msg.height then
		changed = msg.height ~= state.height or msg.width ~= state.width
		s.height = msg.height
		s.width = msg.width
	end
	if not changed then
		return state, effects
	end
	settle(s)
	return s, effects
end

function M.save(s: State): any
	local tg = M.target(s)
	return {
		v = M.SAVE_VERSION,
		connection = if tg then tg.id else nil,
		filter = s.filterText,
		level = s.level,
	}
end

return M
