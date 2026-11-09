--!strict
-- State of the `console` block: a read-only SuiteQL console. `update`
-- returns the next state and the effects the host runs (query through
-- NsHost, write history and saved queries, list and read .sql files, copy,
-- export, open the record inspector, move the focus). Nothing here touches
-- `tern`.
--
-- The console runs only a single SELECT or WITH query, whatever the
-- connection's `read_only` says (NsHost and the window check read-only
-- connections again). Every run carries a token (`req`); a later run
-- replaces it, so a late answer of an earlier one changes nothing.

local Config = require("../config")
local Connect = require("../ns/connect")
local Editor = require("./editor")
local Errors = require("../ns/errors")
local Export = require("./export")
local Grid = require("./grid")
local Library = require("./library")
local Link = require("./link")
local LogsLink = require("../monitor/logs/link")
local Sql = require("../ns/sql")
local Sqltext = require("./sqltext")
local Store = require("./store")

type NsError = Errors.NsError

local M = {}

export type Target = Connect.Target
export type Key = Editor.Key
export type Focus = "editor" | "grid" | "filter" | "picker" | "name"

export type Env = {
	-- The JSON null sentinel of the host's decoder (`tern.json.null`).
	null: any,
}

-- What the host read from plugin data before the block started.
export type Data = {
	history: { Store.HistoryEntry },
	saved: { Store.Saved },
	-- The connection the last console ran on (tern.kv), if any.
	lastConnection: string?,
}

export type Result = {
	connection: string,
	account: string,
	production: boolean,
	sql: string,
	columns: { string },
	rows: { any },
	truncated: boolean,
	pages: number,
	-- The window's time for the HTTP requests, and the whole wait.
	ms: number?,
	elapsed: number?,
	at: string?,
	maxRows: number,
	widths: { number },
	-- The table of a single-table query: the record type of `id`.
	table: string?,
	-- Lower-cased cell text per row, built on the first filter.
	hay: { string }?,
}

export type View = {
	-- Index into result.columns.
	sortCol: number?,
	sortDir: Grid.Dir,
	filterText: string,
	-- Row indices in display order.
	order: { number },
	-- Position in `order` of the selected row.
	sel: number,
	-- Current column and the first drawn one.
	col: number,
	firstCol: number,
	-- First drawn row position.
	offset: number,
	inspect: boolean,
}

export type Picker = {
	text: string,
	sel: number,
	items: { Library.Item },
	files: { Library.FileEntry },
	problems: { string },
	loading: boolean,
}

export type Notice = { tone: "info" | "success" | "warning" | "error", text: string }

export type Running = { connection: string, production: boolean, sql: string }

export type Effect = {
	t: "query" | "history" | "list" | "read" | "store" | "delete" | "export" | "inspect" | "open" | "focus",
	req: number?,
	connection: string?,
	sql: string?,
	max_rows: number?,
	path: string?,
	run: boolean?,
	name: string?,
	-- export: "copy" (clipboard), "file" (next to cwd), "view" (Tern's table viewer)
	how: string?,
	format: Export.Format?,
	text: string?,
	cwd: string?,
	id: string?,
	type: string?,
	url: string?,
}

export type Msg = {
	t: "key" | "action" | "focus" | "result" | "listed" | "loaded" | "stored" | "notice" | "resize",
	key: Key?,
	act: string?,
	value: string?,
	-- focus: the node id that was clicked.
	id: string?,
	req: number?,
	rows: { any }?,
	truncated: boolean?,
	pages: number?,
	ms: number?,
	elapsed: number?,
	at: string?,
	err: NsError?,
	saved: { Store.Saved }?,
	files: { Library.FileEntry }?,
	problems: { string }?,
	path: string?,
	text: string?,
	run: boolean?,
	tone: string?,
	notice: string?,
	height: number?,
	width: number?,
}

export type State = {
	targets: { Target },
	selected: number,
	env: Env,
	maxRows: number,
	cwd: string?,
	editor: Editor.Field,
	history: { Store.HistoryEntry },
	-- Recalling history: position in `history`, and the text before.
	histPos: number?,
	histDraft: string?,
	saved: { Store.Saved },
	focus: Focus,
	seq: number,
	inflight: number?,
	running: Running?,
	result: Result?,
	view: View?,
	err: NsError?,
	errConnection: string?,
	picker: Picker?,
	name: Editor.Field?,
	notice: Notice?,
	height: number?,
	width: number?,
}

M.SAVE_VERSION = 1
M.EDITOR_ID = "main.sql"
M.FILTER_ID = "main.filter"
M.PICKER_ID = "main.pickfilter"
M.NAME_ID = "main.name"
M.MAX_RENDER_ROWS = Grid.MAX_RENDER_ROWS
-- Lines that are not result rows (header, editor, result head, actions,
-- filter, column head, hints); they size a page (PgUp/PgDn).
M.CHROME_LINES = 22
M.MIN_PAGE = 10
-- Prefix and margins of a grid line.
M.ROW_MARGIN = 6

local FOCUS_IDS: { [string]: Focus } = {
	[M.EDITOR_ID] = "editor",
	[M.FILTER_ID] = "filter",
	[M.PICKER_ID] = "picker",
	[M.NAME_ID] = "name",
}

-- Accessors ---------------------------------------------------------------------

function M.target(s: State): Target?
	return s.targets[s.selected]
end

-- The selected row (a table from NetSuite) and its index in result.rows.
function M.selectedRow(s: State): (any, number?)
	local r, v = s.result, s.view
	if r == nil or v == nil then
		return nil, nil
	end
	local i = v.order[v.sel]
	return if i then r.rows[i] else nil, i
end

function M.page(height: number?): number
	return math.max((height or 40) - M.CHROME_LINES, M.MIN_PAGE)
end

function M.room(width: number?): number
	return math.max((width or 120) - M.ROW_MARGIN, 20)
end

-- Results view ------------------------------------------------------------------

local function newView(): View
	return {
		sortCol = nil,
		sortDir = "asc",
		filterText = "",
		order = {},
		sel = 1,
		col = 1,
		firstCol = 1,
		offset = 1,
		inspect = false,
	}
end

-- Recomputes the row order for the view's sort and filter, keeping the
-- selected row selected when it still shows.
local function reorder(r: Result, v: View, null: any): View
	local before = v.order[v.sel]
	local words = Grid.words(v.filterText)
	local keep: ((number) -> boolean)? = nil
	if #words > 0 then
		if r.hay == nil then
			local hay: { string } = table.create(#r.rows)
			for i, row in r.rows do
				hay[i] = Grid.haystack(row, r.columns, null)
			end
			r.hay = hay
		end
		local hay = r.hay :: { string }
		keep = function(i: number): boolean
			return Grid.matches(hay[i], words)
		end
	end
	local col = if v.sortCol then r.columns[v.sortCol] else nil
	local nv = table.clone(v)
	nv.order = Grid.order(r.rows, col, v.sortDir, keep, null)
	nv.sel = 1
	if before then
		local at = table.find(nv.order, before)
		if at then
			nv.sel = at
		end
	end
	return nv
end

local function moveRow(s: State, delta: number)
	local v = s.view
	if v == nil or #v.order == 0 then
		return
	end
	local nv = table.clone(v)
	nv.sel = math.clamp(v.sel + delta, 1, #v.order)
	s.view = nv
end

local function moveCol(s: State, delta: number)
	local v, r = s.view, s.result
	if v == nil or r == nil or #r.columns == 0 then
		return
	end
	local nv = table.clone(v)
	nv.col = math.clamp(v.col + delta, 1, #r.columns)
	s.view = nv
end

local function cycleSort(s: State, col: number)
	local v, r = s.view, s.result
	if v == nil or r == nil or r.columns[col] == nil then
		return
	end
	local nv = table.clone(v)
	nv.col = col
	if v.sortCol ~= col then
		nv.sortCol, nv.sortDir = col, "asc"
	elseif v.sortDir == "asc" then
		nv.sortDir = "desc"
	else
		nv.sortCol, nv.sortDir = nil, "asc"
	end
	s.view = reorder(r, nv, s.env.null)
end

local function setFilter(s: State, text: string)
	local v, r = s.view, s.result
	if v == nil or r == nil then
		return
	end
	local nv = table.clone(v)
	nv.filterText = text
	s.view = reorder(r, nv, s.env.null)
end

-- Running -----------------------------------------------------------------------

local function notice(s: State, tone: "info" | "success" | "warning" | "error", text: string)
	s.notice = { tone = tone, text = text }
end

local function run(s: State, effects: { Effect })
	local sql = s.editor.text
	if not string.find(sql, "%S") then
		notice(s, "info", "Type a SuiteQL query first, then press Ctrl+Enter.")
		return
	end
	local tg = M.target(s)
	if tg == nil then
		s.err = Errors.new(
			"query",
			"no connection is configured; add one to connections[] (Tern NetSuite: Open config)",
			Errors.NO_CONNECTION
		)
		s.errConnection = nil
		return
	end
	s.history = Store.addHistory(s.history, { sql = sql, connection = tg.id, at = 0 })
	s.histPos, s.histDraft = nil, nil
	table.insert(effects, { t = "history", sql = sql, connection = tg.id })
	local ok, why = Sql.readOnly(sql)
	if not ok then
		s.err = Errors.new(
			"query",
			"refused by the console's read-only guard: " .. (why or "not a query"),
			Errors.READ_ONLY
		)
		s.errConnection = tg.id
		s.inflight, s.running = nil, nil
		return
	end
	s.seq += 1
	s.inflight = s.seq
	s.running = { connection = tg.id, production = tg.production, sql = sql }
	s.err, s.errConnection = nil, nil
	s.notice = nil
	table.insert(effects, { t = "query", req = s.seq, connection = tg.id, sql = sql, max_rows = s.maxRows })
end

local function onResult(s: State, msg: Msg): boolean
	if msg.req == nil or msg.req ~= s.inflight then
		return false
	end
	local running = s.running :: Running
	s.inflight, s.running = nil, nil
	if msg.err then
		s.err = msg.err
		s.errConnection = running.connection
		return true
	end
	local rows: { any } = msg.rows or {}
	local columns = Sqltext.columns(running.sql, rows)
	local account = running.connection
	for _, tg in s.targets do
		if tg.id == running.connection then
			account = tg.account_label
		end
	end
	local r: Result = {
		connection = running.connection,
		account = account,
		production = running.production,
		sql = running.sql,
		columns = columns,
		rows = rows,
		truncated = msg.truncated == true,
		pages = msg.pages or 0,
		ms = msg.ms,
		elapsed = msg.elapsed,
		at = msg.at,
		maxRows = s.maxRows,
		widths = Grid.widths(columns, rows, s.env.null),
		table = Sqltext.fromTable(running.sql),
		hay = nil,
	}
	s.result = r
	s.view = reorder(r, newView(), s.env.null)
	s.err, s.errConnection = nil, nil
	return true
end

-- The record a row's cell names, preferring `column`.
local function inspectEffect(s: State, column: string?): Effect?
	local r = s.result
	local row = M.selectedRow(s)
	if r == nil or row == nil then
		return nil
	end
	local cells = Grid.idCells(row, r.columns)
	local pick = cells[1]
	for _, c in cells do
		if c.column == column then
			pick = c
		end
	end
	if pick == nil then
		return nil
	end
	return {
		t = "inspect",
		connection = r.connection,
		id = pick.id,
		type = if string.lower(pick.column) == "id" then r.table else nil,
	}
end

local function exportEffect(s: State, how: string, format: Export.Format): Effect?
	local r, v = s.result, s.view
	if r == nil or v == nil then
		return nil
	end
	return {
		t = "export",
		how = how,
		format = format,
		text = Export.text(format, r.columns, r.rows, v.order, s.env.null),
		connection = r.connection,
		cwd = s.cwd,
	}
end

-- Editor and history ------------------------------------------------------------

local function load(s: State, sql: string)
	s.editor = Editor.set(s.editor, sql)
	s.histPos, s.histDraft = nil, nil
	s.focus = "editor"
end

local function recall(s: State, older: boolean): boolean
	local n = #s.history
	if n == 0 then
		return false
	end
	local pos = s.histPos
	if older then
		if pos == nil then
			s.histDraft = s.editor.text
			pos = n
		elseif pos > 1 then
			pos -= 1
		else
			return false
		end
	else
		if pos == nil then
			return false
		elseif pos < n then
			pos += 1
		else
			-- Past the newest entry: back to what was being written.
			local draft = s.histDraft or ""
			s.histPos, s.histDraft = nil, nil
			s.editor = { text = draft, cursor = #draft, undo = s.editor.undo, typing = false }
			return true
		end
	end
	s.histPos = pos
	local sql = s.history[pos :: number].sql
	-- Older entries put the caret on their first line, so Up keeps going
	-- back; newer ones on their last line, so Down keeps going forward.
	local cursor = if older then (string.find(sql, "\n", 1, true) or (#sql + 1)) - 1 else #sql
	s.editor = { text = sql, cursor = cursor, undo = s.editor.undo, typing = false }
	return true
end

-- Picker and name prompt ---------------------------------------------------------

local function openPicker(s: State, effects: { Effect })
	s.picker = { text = "", sel = 1, items = {}, files = {}, problems = {}, loading = true }
	s.focus = "picker"
	table.insert(effects, { t = "list", cwd = s.cwd })
end

local function pickerItems(p: Picker): { Library.Item }
	return Library.filter(p.items, p.text)
end

local function choose(s: State, item: Library.Item, runNow: boolean, effects: { Effect })
	s.picker = nil
	if item.kind == "saved" and item.sql then
		load(s, item.sql)
		if runNow then
			run(s, effects)
		end
	elseif item.path then
		s.focus = "editor"
		table.insert(effects, { t = "read", path = item.path, run = runNow })
	end
end

local function openName(s: State)
	local default = Sqltext.title(s.editor.text) or ""
	if s.histPos == nil then
		for _, e in s.saved do
			if e.sql == s.editor.text then
				default = e.name
			end
		end
	end
	s.name = Editor.new(default)
	s.focus = "name"
end

local function lineKey(f: Editor.Field, key: Key): Editor.Field?
	if key.name == "enter" or key.name == "return" or key.name == "up" or key.name == "down" then
		return nil
	end
	if key.name == "paste" then
		local line = string.gsub(key.text or "", "[\r\n\t]+", " ")
		return Editor.key(f, { name = "paste", text = line })
	end
	return Editor.key(f, key)
end

-- Keys --------------------------------------------------------------------------

local function isRun(key: Key): boolean
	return (key.name == "enter" or key.name == "return") and (key.ctrl == true or key.meta == true)
end

local function cycleTarget(s: State): boolean
	if #s.targets < 2 then
		return false
	end
	s.selected = s.selected % #s.targets + 1
	return true
end

local function editorKey(s: State, key: Key, effects: { Effect }): boolean
	local name = key.name
	local plain = not (key.ctrl or key.meta or key.alt or key.shift)
	if isRun(key) then
		run(s, effects)
		return true
	elseif key.ctrl and name == "o" then
		openPicker(s, effects)
		return true
	elseif key.ctrl and name == "s" then
		openName(s)
		return true
	elseif (name == "tab" or name == "escape") and plain then
		if s.result == nil then
			return false
		end
		s.focus = "grid"
		return true
	elseif name == "up" and plain and Editor.onFirstLine(s.editor) then
		return recall(s, true)
	elseif name == "down" and plain and Editor.onLastLine(s.editor) then
		return recall(s, false)
	end
	local f = Editor.key(s.editor, key)
	if f == nil then
		return false
	end
	if f.text ~= s.editor.text then
		s.histPos, s.histDraft = nil, nil
	end
	s.editor = f
	return true
end

local function filterKey(s: State, key: Key): boolean
	local v = s.view
	if v == nil then
		s.focus = "editor"
		return true
	end
	local name = key.name
	if name == "enter" or name == "return" or name == "escape" or name == "tab" then
		s.focus = "grid"
		return true
	elseif name == "down" then
		moveRow(s, 1)
		return true
	elseif name == "up" then
		moveRow(s, -1)
		return true
	end
	local f = lineKey(Editor.new(v.filterText), key)
	if f == nil then
		return false
	end
	setFilter(s, f.text)
	return true
end

local function pickerKey(s: State, key: Key, effects: { Effect }): boolean
	local p = s.picker
	if p == nil then
		s.focus = "editor"
		return true
	end
	local name = key.name
	local list = pickerItems(p)
	if name == "escape" then
		s.picker = nil
		s.focus = "editor"
	elseif name == "down" or name == "up" then
		local np = table.clone(p)
		np.sel = math.clamp(p.sel + (if name == "down" then 1 else -1), 1, math.max(#list, 1))
		s.picker = np
	elseif name == "enter" or name == "return" then
		local item = list[p.sel]
		if item == nil then
			return false
		end
		choose(s, item, isRun(key), effects)
	elseif (key.ctrl and name == "d") or (name == "delete" and (key.meta or key.ctrl)) then
		local item = list[p.sel]
		if item == nil or item.kind ~= "saved" or item.name == nil then
			notice(s, "info", "Only queries saved in Tern NetSuite can be deleted here; folder files are read-only.")
			return true
		end
		table.insert(effects, { t = "delete", name = item.name })
	else
		local f = lineKey(Editor.new(p.text), key)
		if f == nil then
			return false
		end
		local np = table.clone(p)
		np.text = f.text
		np.sel = 1
		s.picker = np
	end
	return true
end

local function nameKey(s: State, key: Key, effects: { Effect }): boolean
	local f = s.name or Editor.new("")
	local name = key.name
	if name == "escape" then
		s.name = nil
		s.focus = "editor"
	elseif name == "enter" or name == "return" then
		local n, why = Store.name(f.text)
		if n == nil then
			notice(s, "warning", "Not saved: " .. (why or "invalid name"))
			return true
		end
		table.insert(effects, { t = "store", name = n, sql = s.editor.text })
		s.name = nil
		s.focus = "editor"
	else
		local nf = lineKey(f, key)
		if nf == nil then
			return false
		end
		s.name = nf
	end
	return true
end

local function gridKey(s: State, key: Key, effects: { Effect }): boolean
	local name = key.name
	local ch = Editor.printable(key)
	local page = M.page(s.height)
	if isRun(key) or ch == "r" then
		run(s, effects)
	elseif key.ctrl and name == "o" then
		openPicker(s, effects)
	elseif key.ctrl and name == "s" then
		openName(s)
	elseif ch == "j" or name == "down" then
		moveRow(s, 1)
	elseif ch == "k" or name == "up" then
		moveRow(s, -1)
	elseif name == "page_down" then
		moveRow(s, page)
	elseif name == "page_up" then
		moveRow(s, -page)
	elseif ch == "g" or name == "home" then
		moveRow(s, -math.huge)
	elseif ch == "G" or name == "end" then
		moveRow(s, math.huge)
	elseif ch == "h" or name == "left" then
		moveCol(s, -1)
	elseif ch == "l" or name == "right" then
		moveCol(s, 1)
	elseif ch == "s" then
		cycleSort(s, if s.view then (s.view :: View).col else 1)
	elseif ch == "/" then
		if s.view == nil then
			return false
		end
		s.focus = "filter"
	elseif name == "enter" or name == "return" then
		if s.view == nil then
			return false
		end
		local nv = table.clone(s.view :: View)
		nv.inspect = not nv.inspect
		s.view = nv
	elseif ch == "i" then
		local e =
			inspectEffect(s, if s.result and s.view then (s.result :: Result).columns[(s.view :: View).col] else nil)
		if e == nil then
			notice(s, "info", "This row has no record id to inspect (an id or *id column with an internal id).")
			return true
		end
		table.insert(effects, e)
		return false
	elseif ch == "y" or ch == "Y" or ch == "w" or ch == "W" or ch == "o" then
		local how = if ch == "y" or ch == "Y" then "copy" elseif ch == "o" then "view" else "file"
		local format: Export.Format = if ch == "Y" then "tsv" elseif ch == "W" then "json" else "csv"
		local e = exportEffect(s, how, format)
		if e == nil then
			return false
		end
		table.insert(effects, e)
		return false
	elseif ch == "c" then
		return cycleTarget(s)
	elseif name == "escape" then
		local v = s.view
		if v and v.inspect then
			local nv = table.clone(v)
			nv.inspect = false
			s.view = nv
		else
			s.focus = "editor"
		end
	elseif name == "tab" or ch == "e" then
		s.focus = "editor"
	else
		return false
	end
	return true
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	if s.notice and s.focus ~= "name" then
		s.notice = nil
	end
	local f = s.focus
	if f == "picker" then
		return pickerKey(s, key, effects)
	elseif f == "name" then
		return nameKey(s, key, effects)
	elseif f == "filter" then
		return filterKey(s, key)
	elseif f == "grid" and s.result then
		return gridKey(s, key, effects)
	end
	return editorKey(s, key, effects)
end

-- Clicks ------------------------------------------------------------------------

local function onAction(s: State, act: string, value: string, effects: { Effect }): boolean
	if act == "run" then
		run(s, effects)
	elseif act == "conn" then
		for i, tg in s.targets do
			if tg.id == value and i ~= s.selected then
				s.selected = i
				return true
			end
		end
		return false
	elseif act == "picker" then
		openPicker(s, effects)
	elseif act == "save" then
		openName(s)
	elseif act == "name-save" then
		return nameKey(s, { name = "enter" }, effects)
	elseif act == "name-cancel" or act == "picker-close" then
		s.name, s.picker = nil, nil
		s.focus = "editor"
	elseif act == "pick" or act == "pick-run" then
		local p = s.picker
		local item = if p then pickerItems(p)[tonumber(value) or 0] else nil
		if item == nil then
			return false
		end
		choose(s, item, act == "pick-run", effects)
	elseif act == "export" then
		local how, format = string.match(value, "^(%a+):(%a+)$")
		if
			how == nil
			or format == nil
			or Export.EXTENSIONS[format] == nil
			or not (how == "copy" or how == "file" or how == "view")
		then
			return false
		end
		local e = exportEffect(s, how, format :: Export.Format)
		if e then
			table.insert(effects, e)
		end
		return false
	elseif act == "inspect" then
		local e = inspectEffect(s, value)
		if e then
			table.insert(effects, e)
		end
		return false
	elseif act == "row" then
		local v = s.view
		local pos = tonumber(value)
		if v == nil or pos == nil or v.order[pos] == nil then
			return false
		end
		local nv = table.clone(v)
		nv.inspect = if pos == v.sel then not v.inspect else true
		nv.sel = pos
		s.view = nv
		s.focus = "grid"
	elseif act == "sort" then
		local col = tonumber(value)
		if col == nil then
			return false
		end
		cycleSort(s, col)
		s.focus = "grid"
	elseif act == "filter-clear" then
		setFilter(s, "")
		s.focus = "grid"
	elseif act == "inspect-close" then
		local v = s.view
		if v == nil then
			return false
		end
		local nv = table.clone(v)
		nv.inspect = false
		s.view = nv
	elseif act == "connect" then
		local id = s.errConnection or (M.target(s) and (M.target(s) :: Target).id)
		if id == nil then
			return false
		end
		table.insert(effects, { t = "open", url = LogsLink.connectUrl(id) })
		return false
	else
		return false
	end
	return true
end

-- Keeps the drawn windows of rows and columns around the selection.
local function settle(s: State)
	local r, v = s.result, s.view
	if r == nil or v == nil then
		return
	end
	local first = Grid.window(v.sel, #v.order, v.offset, M.MAX_RENDER_ROWS)
	local firstCol = Grid.columnWindow(r.widths, v.col, v.firstCol, M.room(s.width))
	if first ~= v.offset or firstCol ~= v.firstCol then
		local nv = table.clone(v)
		nv.offset = first
		nv.firstCol = firstCol
		s.view = nv
	end
end

-- Init / update -----------------------------------------------------------------

function M.init(args: { string }, saved: any, cfg: Config.Config, env: Env, data: Data): (State, { Effect })
	local launch, problems = Link.fromArgs(args)
	local targets = Connect.targets(cfg)
	local s: State = {
		targets = targets,
		selected = if #targets > 0 then 1 else 0,
		env = env,
		maxRows = cfg.console.max_rows,
		cwd = launch.cwd,
		editor = Editor.new(""),
		history = data.history,
		histPos = nil,
		histDraft = nil,
		saved = data.saved,
		focus = "editor",
		seq = 0,
		inflight = nil,
		running = nil,
		result = nil,
		view = nil,
		err = nil,
		errConnection = nil,
		picker = nil,
		name = nil,
		notice = if #problems > 0
			then { tone = "warning", text = "Ignored launch arguments: " .. table.concat(problems, "; ") }
			else nil,
		height = nil,
		width = nil,
	}
	local restored = type(saved) == "table" and saved.v == M.SAVE_VERSION
	if restored then
		if type(saved.sql) == "string" then
			s.editor = Editor.new(saved.sql)
		end
		if s.cwd == nil and type(saved.cwd) == "string" then
			s.cwd = saved.cwd
		end
	end
	local wanted = launch.connection
		or (if restored and type(saved.connection) == "string" then saved.connection else nil)
		or data.lastConnection
	if wanted then
		for i, tg in targets do
			if tg.id == wanted then
				s.selected = i
			end
		end
		if launch.connection and (M.target(s) == nil or (M.target(s) :: Target).id ~= launch.connection) then
			s.err = Errors.new(
				"query",
				string.format("no connection %q in the config (connections[])", launch.connection),
				Errors.NO_CONNECTION
			)
		end
	end
	local effects: { Effect } = {}
	-- A restored console never runs again on its own.
	local runNow = launch.run == true and not restored
	local tg = M.target(s)
	if runNow and tg and tg.production then
		runNow = false
		notice(s, "warning", string.format("%s is a production connection: press Ctrl+Enter to run the query.", tg.id))
	end
	if launch.file and not restored then
		table.insert(effects, { t = "read", path = launch.file, run = runNow })
	elseif launch.saved and not restored then
		local q = Store.find(data.saved, launch.saved)
		if q then
			load(s, q.sql)
			if runNow then
				run(s, effects)
			end
		else
			notice(s, "warning", string.format("No saved query is named %q.", launch.saved))
		end
	end
	if launch.pick and not restored then
		openPicker(s, effects)
	end
	-- The host applies it once the first view is drawn.
	table.insert(effects, { t = "focus", id = M.focusId(s.focus) })
	return s, effects
end

local function focusId(f: Focus): string?
	if f == "editor" then
		return M.EDITOR_ID
	elseif f == "filter" then
		return M.FILTER_ID
	elseif f == "picker" then
		return M.PICKER_ID
	elseif f == "name" then
		return M.NAME_ID
	end
	return nil
end

M.focusId = focusId

-- Returns the same state table when the message changed nothing.
function M.update(state: State, msg: Msg): (State, { Effect })
	local s = table.clone(state)
	local effects: { Effect } = {}
	local changed = false
	local t = msg.t
	if t == "key" and msg.key then
		changed = onKey(s, msg.key, effects)
	elseif t == "action" and msg.act then
		changed = onAction(s, msg.act, msg.value or "", effects)
	elseif t == "focus" and msg.id then
		local f: Focus? = FOCUS_IDS[msg.id]
		if f and f ~= s.focus and (f ~= "filter" or s.view ~= nil) then
			if f ~= "picker" then
				s.picker = nil
			end
			if f ~= "name" then
				s.name = nil
			end
			s.focus = f :: Focus
			changed = true
		end
	elseif t == "result" then
		changed = onResult(s, msg)
	elseif t == "listed" then
		local p = s.picker
		s.saved = msg.saved or s.saved
		if p then
			local np = table.clone(p)
			np.files = msg.files or {}
			np.items = Library.items(s.saved, np.files)
			np.problems = msg.problems or {}
			np.loading = false
			s.picker = np
		end
		changed = true
	elseif t == "stored" then
		s.saved = msg.saved or s.saved
		local p = s.picker
		if p then
			local np = table.clone(p)
			np.items = Library.items(s.saved, p.files)
			np.sel = math.clamp(p.sel, 1, math.max(#pickerItems(np), 1))
			s.picker = np
		end
		if msg.notice then
			notice(s, (msg.tone or "success") :: any, msg.notice)
		end
		changed = true
	elseif t == "loaded" then
		if msg.text then
			load(s, msg.text)
			if msg.run then
				run(s, effects)
			end
		else
			notice(s, "error", msg.notice or "The query file could not be read.")
		end
		changed = true
	elseif t == "notice" and msg.notice then
		notice(s, (msg.tone or "info") :: any, msg.notice)
		changed = true
	elseif t == "resize" and msg.height then
		changed = msg.height ~= state.height or msg.width ~= state.width
		s.height = msg.height
		s.width = msg.width
	end
	if not changed then
		return state, effects
	end
	settle(s)
	if s.focus ~= state.focus then
		table.insert(effects, { t = "focus", id = focusId(s.focus) })
	end
	return s, effects
end

function M.save(s: State): any
	local tg = M.target(s)
	return {
		v = M.SAVE_VERSION,
		connection = if tg then tg.id else nil,
		sql = if #s.editor.text <= Store.MAX_SQL_BYTES then s.editor.text else nil,
		cwd = s.cwd,
	}
end

function M.title(s: State): string
	local tg = M.target(s)
	if tg == nil then
		return "SuiteQL console"
	end
	return "SuiteQL · " .. tg.id .. (if tg.production then " (PROD)" else "")
end

return M
